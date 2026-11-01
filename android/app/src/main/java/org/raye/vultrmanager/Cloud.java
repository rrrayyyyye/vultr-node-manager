package org.raye.vultrmanager;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Only fixed, authenticated Vultr endpoints. Never log response bodies or credentials. */
final class Cloud {
    interface Transport { JSONObject request(String method,String path,JSONObject body,int timeout) throws Exception; }
    static class ApiError extends Exception {
        final int status;
        ApiError(int s) { super("Vultr API 返回 HTTP "+s+(s==401||s==403?"，请检查密钥、权限及来源 IP 限制":"")); status=s; }
    }
    static final class WriteUncertain extends Exception {
        WriteUncertain() { super("销毁请求可能已经送达，须刷新云端确认；不会自动重发"); }
    }
    static final class Http implements Transport {
        private final String key;
        Http(String key) { this.key=key; }
        public JSONObject request(String method,String path,JSONObject body,int timeout) throws Exception {
            if (!path.startsWith("/") || path.contains(":") || path.startsWith("//")) throw new Exception("无效 API 路径");
            int attempts=method.equals("GET")&&timeout!=6000?2:1;
            for(int attempt=0;;attempt++) {
                try { return jsonRequest(new URL("https://api.vultr.com/v2"+path),method,key,body,timeout); }
                catch(IOException e) { if(attempt+1>=attempts) throw new IOException("管理 API 连接失败；请检查直连网络、VPN 分流及 API 来源 IP 限制。云端状态尚未确认"); }
            }
        }
    }
    static JSONObject jsonRequest(URL url,String method,String key,JSONObject body,int timeout) throws Exception {
        HttpURLConnection c=(HttpURLConnection)url.openConnection(Proxy.NO_PROXY);
        c.setInstanceFollowRedirects(false);
        c.setConnectTimeout(timeout); c.setReadTimeout(timeout);
        c.setRequestMethod(method);
        c.setRequestProperty("Accept","application/json");
        c.setRequestProperty("Connection","close");
        if(key!=null) c.setRequestProperty("Authorization","Bearer "+key);
        try {
            if(body!=null) {
                byte[] data=body.toString().getBytes(StandardCharsets.UTF_8);
                c.setRequestProperty("Content-Type","application/json"); c.setDoOutput(true);
                c.setFixedLengthStreamingMode(data.length);
                try(OutputStream o=c.getOutputStream()) { o.write(data); }
            }
            int status=c.getResponseCode();
            if(status<200||status>=300) throw new ApiError(status);
            if(status==204) return new JSONObject();
            String raw;
            try(InputStream in=c.getInputStream()) { raw=readLimited(in,4*1024*1024); }
            return raw.trim().isEmpty()?new JSONObject():new JSONObject(raw);
        } finally { c.disconnect(); }
    }
    static String readLimited(InputStream in,int limit) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream(); byte[] bytes=new byte[8192]; int n;
        while((n=in.read(bytes))!=-1) { if(out.size()+n>limit) throw new IOException("文件或响应过大"); out.write(bytes,0,n); }
        return out.toString(StandardCharsets.UTF_8.name());
    }
    private final Transport api;
    Cloud(Transport t) { api=t; }
    List<Models.Instance> list() throws Exception {
        List<Models.Instance> result=new ArrayList<>(); Set<String> cursors=new HashSet<>(),ids=new HashSet<>();
        String cursor="";
        for(int page=0;page<1000;page++) {
            JSONObject root=api.request("GET","/instances?per_page=100"+(cursor.isEmpty()?"":"&cursor="+URLEncoder.encode(cursor,StandardCharsets.UTF_8.name())),null,8000);
            JSONArray rows=root.getJSONArray("instances");
            for(int i=0;i<rows.length();i++) {
                Models.Instance instance=Models.instance(rows.getJSONObject(i));
                if(!ids.add(instance.id())) throw new Exception("实例分页包含重复 ID，暂不能确认完整状态");
                result.add(instance);
            }
            JSONObject links=root.getJSONObject("meta").getJSONObject("links");
            if(!links.has("next")) throw new Exception("实例分页信息缺失，暂不能确认完整状态");
            cursor=links.isNull("next")?"":links.getString("next");
            if(cursor.isEmpty()) return result;
            if(cursor.length()>4096||!cursors.add(cursor)) throw new Exception("实例分页游标异常");
        }
        throw new Exception("实例分页数量异常，查询未完成");
    }
    Models.Balance balance() throws Exception { return Models.balance(api.request("GET","/account",null,6000)); }
    Models.Instance create(Models.Node node) throws Exception {
        Models.Instance found=Models.find(list(),node);
        if(found!=null) return found;
        JSONArray plans=api.request("GET","/regions/"+node.region()+"/availability",null,8000).getJSONArray("available_plans");
        boolean available=false;
        for(int i=0;i<plans.length();i++) if(node.plan().equals(plans.getString(i))) available=true;
        if(!available) throw new Exception("所选地区暂无此套餐库存");
        api.request("GET","/startup-scripts/"+node.script(),null,8000).getJSONObject("startup_script");
        // Recheck immediately before the write; local locking cannot lock another host.
        found=Models.find(list(),node);
        if(found!=null) return found;
        JSONObject body=new JSONObject().put("region",node.region()).put("plan",node.plan()).put("os_id",node.osId())
            .put("label",node.label()).put("hostname",node.label()).put("script_id",node.script()).put("backups","disabled").put("enable_ipv6",node.ipv6());
        Models.Instance created=Models.forNode(Models.instance(api.request("POST","/instances",body,60000).getJSONObject("instance")),node);
        if(!created.region().equals(node.region())||!created.label().equals(node.label())) throw new Exception("创建回执身份异常，请刷新云端状态");
        return created;
    }
    void destroy(Models.Node node,String expectedId) throws Exception {
        Models.Instance found=Models.find(list(),node);
        if(found==null) return;
        if(!found.id().equals(expectedId)) throw new Exception("云端实例已被其他设备替换，请刷新后重新确认");
        if(!expectedId.matches("[a-zA-Z0-9-]{1,80}")) throw new Exception("实例 ID 无效");
        try { api.request("DELETE","/instances/"+expectedId,null,60000); }
        catch(ApiError e) { if(e.status>=500||e.status==408)throw new WriteUncertain();throw e; }
        catch(Exception e) { throw new WriteUncertain(); }
    }
    static String checkBasic(Models.Node node,Models.Instance instance) {
        if(instance.ip().isEmpty()||instance.ip().equals("0.0.0.0")) return "公网 IP 尚未分配";
        boolean dns=false,tcp=false;
        try {
            JSONObject result=jsonRequest(new URL("https://223.5.5.5/resolve?name="+URLEncoder.encode(node.domain(),"UTF-8")+"&type="+(node.ipv6()?"AAAA":"A")),"GET",null,null,4000);
            JSONArray answers=result.optJSONArray("Answer");
            if(answers!=null) for(int i=0;i<answers.length();i++) if(answers.getJSONObject(i).optInt("type")== (node.ipv6()?28:1) && sameIp(instance.ip(),answers.getJSONObject(i).optString("data"))) dns=true;
        } catch(Exception ignored) { }
        // Require a literal IPv4 from Vultr rather than inadvertently resolving an arbitrary host.
        if(literalIp(instance.ip()))
            try(Socket s=new Socket(Proxy.NO_PROXY)) { s.connect(new InetSocketAddress(instance.ip(),443),4000); tcp=true; } catch(Exception ignored) { }
        return "域名 "+(dns?"一致":"未确认")+" · TCP 443 "+(tcp?"可达":"未确认");
    }
    static boolean literalIp(String ip) { return ip.matches("([0-9]{1,3}\\.){3}[0-9]{1,3}") || (ip.contains(":")&&ip.matches("[0-9a-fA-F:]+")); }
    static boolean sameIp(String a,String b) {
        if(!literalIp(a)||!literalIp(b))return false;
        try{return InetAddress.getByName(a).equals(InetAddress.getByName(b));}catch(Exception e){return false;}
    }
}
