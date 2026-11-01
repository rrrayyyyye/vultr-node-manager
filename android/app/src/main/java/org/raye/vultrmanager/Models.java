package org.raye.vultrmanager;

import org.json.*;
import java.math.BigDecimal;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

final class Models {
    record Node(String id, String name, String linkName, String region, String label, String domain,
                String script, String plan, int osId, String uuid, String publicKey, String shortId, String sni, String ipVersion) {
        Node(String id,String name,String linkName,String region,String label,String domain,String script,String plan,int osId,String uuid,String publicKey,String shortId,String sni) {
            this(id,name,linkName,region,label,domain,script,plan,osId,uuid,publicKey,shortId,sni,plan.endsWith("-v6")?"ipv6":"ipv4");
        }
        boolean ipv6() { return ipVersion.equals("ipv6") || plan.endsWith("-v6"); }
    }
    record Instance(String id, String region, String label, String status, String power, String ip, Instant created, String ipv6) {
        Instance(String id,String region,String label,String status,String power,String ip,Instant created) {this(id,region,label,status,power,ip,created,"");}
    }
    static Instance forNode(Instance i,Node n) { return n.ipv6()?new Instance(i.id,i.region,i.label,i.status,i.power,i.ipv6,i.created,i.ipv6):i; }
    record Balance(BigDecimal credit, BigDecimal pending, BigDecimal remaining, Instant checked) {}
    record Pending(String instanceId, boolean accepted) {}

    static List<Node> parseConfig(String raw) throws Exception {
        JSONObject root = new JSONObject(raw.replace("\uFEFF", ""));
        if (root.getInt("version") != 1) throw new Exception("不支持的配置版本");
        JSONArray rows = root.getJSONArray("nodes");
        if (rows.length() == 0 || rows.length() > 20) throw new Exception("地区数量须在 1–20 之间");
        List<Node> nodes = new ArrayList<>();
        Set<String> ids = new HashSet<>(), labels = new HashSet<>(), domains = new HashSet<>(), links = new HashSet<>();
        for (int i=0; i<rows.length(); i++) {
            JSONObject n = rows.getJSONObject(i);
            Node node = new Node(field(n,"id"),field(n,"name"),field(n,"linkName"),field(n,"region"),
                field(n,"label"),field(n,"domain"),field(n,"startupScriptId"),field(n,"plan"),n.getInt("osId"),
                field(n,"uuid"),field(n,"publicKey"),field(n,"shortId"),field(n,"sni"),n.optString("ipVersion",n.getString("plan").endsWith("-v6")?"ipv6":"ipv4"));
            if(!List.of("ipv4","ipv6").contains(node.ipVersion) || (node.plan.endsWith("-v6")&&!node.ipVersion.equals("ipv6"))) throw new Exception("无效 IP 版本配置");
            if (!node.id.matches("[a-zA-Z0-9_-]{1,80}") || !node.region.matches("[a-z0-9-]{1,20}") ||
                !node.script.matches("[a-zA-Z0-9-]{1,80}") || !node.plan.matches("[a-zA-Z0-9-]{1,80}") ||
                !host(node.domain) || !host(node.sni) || node.osId<=0 ||
                !node.uuid.matches("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}") ||
                !node.publicKey.matches("[a-zA-Z0-9_-]{43}") || !node.shortId.matches("([a-fA-F0-9]{2}){1,8}"))
                throw new Exception("配置包含占位符或无效连接字段，请从电脑导入真实的 nodes.json");
            if (!ids.add(node.id) || !labels.add(node.label) || !domains.add(node.domain.toLowerCase(Locale.ROOT)) || !links.add(node.linkName))
                throw new Exception("地区 ID、标签、域名和线路名必须各自唯一");
            nodes.add(node);
        }
        return Collections.unmodifiableList(nodes);
    }
    static String field(JSONObject j,String key) throws Exception {
        String v = j.getString(key).trim();
        if (v.isEmpty() || v.length()>256 || v.contains("YOUR_") || v.chars().anyMatch(c->c<32)) throw new Exception("配置缺少有效字段："+key);
        return v;
    }
    static boolean host(String s) { return s.length()<=253 && s.matches("(?i)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?") && s.contains(".") && !s.contains(".."); }
    static String parseKey(String raw) throws Exception {
        String key=raw.replace("\uFEFF","").trim();
        if (!key.matches("[A-Za-z0-9_-]{16,256}") || key.contains("YOUR_")) throw new Exception("API 密钥格式无效，请选择 vultr-api.key");
        return key;
    }
    static Instance instance(JSONObject j) throws Exception {
        Instant created = null;
        try { created=Instant.parse(j.optString("date_created").replace(" ","T").replaceAll("(?<!Z)$","Z")); } catch (Exception ignored) { }
        // Some API dates already include an explicit UTC offset.
        if (created==null) try { created=OffsetDateTime.parse(j.optString("date_created").replace(" ","T")).toInstant(); } catch (Exception ignored) { }
        return new Instance(field(j,"id"),field(j,"region"),j.optString("label",""),field(j,"status"),j.optString("power_status","未知"),j.optString("main_ip",""),created,j.optString("v6_main_ip",""));
    }
    static Instance find(List<Instance> all, Node n) throws Exception {
        List<Instance> matching = new ArrayList<>();
        for (Instance i:all) if (i.label.equals(n.label)) matching.add(i);
        if (matching.size()>1) throw new Exception("发现重复标签，已阻止开关操作；请在 Vultr 控制台检查");
        if (matching.isEmpty()) return null;
        Instance i=matching.get(0);
        if (!i.region.equals(n.region)) throw new Exception("标签出现在其他地区，已阻止开关操作");
        return forNode(i,n);
    }
    static Balance balance(JSONObject root) throws Exception {
        JSONObject a=root.getJSONObject("account");
        BigDecimal credit=new BigDecimal(a.get("balance").toString()).negate();
        BigDecimal pending=new BigDecimal(a.get("pending_charges").toString());
        if (pending.signum()<0) throw new Exception("待结算金额无效");
        return new Balance(credit,pending,credit.subtract(pending),Instant.now());
    }
    static String age(Instant created) {
        if(created==null) return "—";
        long s=Math.max(0,Duration.between(created,Instant.now()).getSeconds());
        return (s>=86400 ? s/86400+"天 " : "")+String.format(Locale.ROOT,"%02d:%02d:%02d",s/3600%24,s/60%60,s%60);
    }
    static String localTime(Instant t) { return t==null?"—":DateTimeFormatter.ofPattern("MM-dd HH:mm:ss XXX").withZone(ZoneId.systemDefault()).format(t); }
    static String money(BigDecimal v) { return v.setScale(2,java.math.RoundingMode.HALF_UP).toPlainString(); }
    static String yamlQuote(String v) { return "'"+v.replace("'","''")+"'"; }
    static String exportYaml(List<Node> nodes) {
        boolean ipv6=nodes.stream().anyMatch(Node::ipv6);
        StringBuilder b=new StringBuilder("mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nipv6: "+ipv6+"\ndns:\n  enable: true\n  ipv6: "+ipv6+"\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  fake-ip-filter:\n    - api.vultr.com\n  nameserver:\n    - https://223.5.5.5/dns-query\n    - https://1.1.1.1/dns-query\n  proxy-server-nameserver:\n    - https://223.5.5.5/dns-query\n    - https://1.1.1.1/dns-query\nproxies:\n");
        for (Node n:nodes) b.append("  - name: ").append(yamlQuote(n.linkName)).append("\n    type: vless\n    server: ").append(yamlQuote(n.domain)).append("\n    ip-version: ").append(n.ipv6()?"ipv6":"ipv4").append("\n    port: 443\n    uuid: ").append(yamlQuote(n.uuid)).append("\n    network: tcp\n    udp: true\n    tls: true\n    flow: xtls-rprx-vision\n    servername: ").append(yamlQuote(n.sni)).append("\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: ").append(yamlQuote(n.publicKey)).append("\n      short-id: ").append(yamlQuote(n.shortId)).append('\n');
        b.append("proxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n");
        for(Node n:nodes) b.append("      - ").append(yamlQuote(n.linkName)).append('\n');
        return b.append("rules:\n  - DOMAIN,api.vultr.com,DIRECT\n  - IP-CIDR,223.5.5.5/32,DIRECT,no-resolve\n  - IP-CIDR,1.1.1.1/32,DIRECT,no-resolve\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n").toString();
    }
}
