package org.raye.vultrmanager;

import android.app.Application;
import android.os.*;
import org.json.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

public final class ManagerApp extends Application {
    static final class State {
        Models.Instance instance;
        Models.Pending pending;
        String message="尚未查询", basic="基础连通尚未检查";
        boolean verified=false,busy=false;
        Instant checked;
    }
    final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService operations=Executors.newSingleThreadExecutor(), accountPool=Executors.newSingleThreadExecutor(), checks=Executors.newFixedThreadPool(2);
    final Map<String,State> states=new LinkedHashMap<>();
    final List<String> journal=new ArrayList<>();
    List<Models.Node> nodes=Collections.emptyList();
    Models.Balance balance;
    String accountError="尚未查询",setupError="";
    boolean refreshing=false,accountBusy=false,configured=false;
    Runnable listener;
    Cloud cloud; // Package visibility allows the isolated instrumentation runner to inject a mock.
    private Vault vault;
    private JSONObject saved=new JSONObject();
    boolean demo=false;

    @Override public void onCreate() {
        super.onCreate(); vault=new Vault(this);
        try {
            saved=vault.load();
            if(saved.has("config")&&saved.has("key")) {
                activate(saved.getString("config"),saved.getString("key"));
                JSONObject pending=saved.optJSONObject("pending");
                if(pending!=null) for(Models.Node n:nodes) if(pending.has(n.id())) {
                    JSONObject p=pending.getJSONObject(n.id());
                    State s=states.get(n.id());
                    s.pending=new Models.Pending(p.getString("id"),p.optBoolean("accepted")); s.message="销毁结果待确认";
                }
            }
        } catch(Exception e) { setupError="本地配置无法读取，请重新导入两个文件。已有云服务器不受影响。"; }
    }
    void changed() { if(listener!=null) listener.run(); }
    void log(String text) { journal.add(Models.localTime(Instant.now())+"  "+text); if(journal.size()>100)journal.remove(0); }
    private void activate(String config,String key) throws Exception {
        nodes=Models.parseConfig(config); cloud=new Cloud(new Cloud.Http(Models.parseKey(key)));
        states.clear(); for(Models.Node n:nodes) states.put(n.id(),new State()); configured=true;
    }
    void install(String config,String key) throws Exception {
        List<Models.Node> parsed=Models.parseConfig(config); String validated=Models.parseKey(key);
        // Keep both settings as one atomic encrypted record; never accept half an import.
        JSONObject next=new JSONObject().put("config",config).put("key",validated);
        vault.save(next); saved=next; demo=false; balance=null; accountError="尚未查询"; setupError="";
        activate(config,validated); log("本地配置已导入，共 "+parsed.size()+" 个地区"); refresh();
    }
    boolean busy() { if(refreshing||accountBusy)return true; for(State s:states.values())if(s.busy)return true; return false; }
    boolean hasPending() { for(State s:states.values())if(s.pending!=null)return true; return false; }
    void clear() throws Exception {
        if(busy()||hasPending())throw new Exception("请先完成当前操作和销毁确认，再清除本地配置");
        vault.clear(); saved=new JSONObject(); nodes=Collections.emptyList();states.clear();balance=null;configured=false;demo=false;changed();
    }
    private void persistPending() throws Exception {
        JSONObject p=new JSONObject();
        for(Map.Entry<String,State> entry:states.entrySet()) if(entry.getValue().pending!=null) p.put(entry.getKey(),new JSONObject()
            .put("id",entry.getValue().pending.instanceId()).put("accepted",entry.getValue().pending.accepted()));
        saved.put("pending",p); vault.save(saved);
    }
    private void applyList(List<Models.Instance> list) {
        for(Models.Node n:nodes) {
            State s=states.get(n.id());
            try {
                Models.Instance found=Models.find(list,n);
                if(s.pending!=null&&(found==null||!found.id().equals(s.pending.instanceId()))) s.pending=null;
                s.instance=found;s.verified=true;s.checked=Instant.now();s.basic="基础连通尚未检查";
                s.message=s.pending!=null?"销毁处理中，等待云端确认":found==null?"未创建 / 已销毁":found.status().equals("active")?(found.power().equals("running")?"运行中":"实例存在 · "+found.power()):"创建中 · "+found.status();
            } catch(Exception e) { fail(s,e); }
        }
        try { persistPending(); } catch(Exception e) { log("本地操作记录保存失败，请保持应用开启并确认云端结果"); }
        changed();
    }
    private void fail(State s,Exception e) {
        s.verified=false;s.basic="基础连通尚未确认";
        s.message=s.pending!=null?(s.pending.accepted()?"销毁已受理，网络未能确认结果":"销毁结果待确认，请刷新"):"查询失败，未确认云端状态";
    }
    void refresh() {
        if(!configured||refreshing||demo)return;
        for(State s:states.values())if(s.busy)return;
        refreshing=true;changed();
        operations.execute(()->{
            try {
                List<Models.Instance> list=cloud.list();
                main.post(()->{ applyList(list);refreshing=false;log("云端实例查询完成");changed();startChecks(); });
            } catch(Exception e) {
                String error=safe(e);
                main.post(()->{ for(State s:states.values())fail(s,e);refreshing=false;log(error);changed(); });
            }
        });
        if(!hasPending()) refreshBalance();
    }
    void refreshBalance() {
        if(!configured||demo||accountBusy)return;
        accountBusy=true;changed();
        accountPool.execute(()->{
            Models.Balance next=null;String error="";
            try { next=cloud.balance(); } catch(Exception e) { error=safe(e); }
            Models.Balance result=next;String message=error;
            main.post(()->{ accountBusy=false;if(result!=null) { balance=result;accountError=""; } else { accountError=message;log("账户查询失败："+message); }changed(); });
        });
    }
    private void startChecks() {
        for(Models.Node n:nodes) {
            State s=states.get(n.id());
            if(s.instance==null||!s.verified||s.pending!=null)continue;
            Models.Instance current=s.instance;
            checks.execute(()->{
                String result=Cloud.checkBasic(n,current);
                main.post(()->{ if(s.instance==current&&s.verified&&s.pending==null){s.basic=result;changed();} });
            });
        }
    }
    void create(Models.Node node) {
        State s=states.get(node.id());if(demo||busy()||s.pending!=null)return;
        s.busy=true;s.verified=false;s.message="正在检查并创建…";log(node.name()+"：开始创建前检查");changed();
        operations.execute(()->{
            try {
                Models.Instance instance=cloud.create(node);
                main.post(()->{s.instance=instance;s.verified=true;s.message="实例已存在 / 初始化中";s.checked=Instant.now();log(node.name()+"：已取得实例回执，初始化仍需几分钟");changed();});
                for(int round=0;round<12;round++) {
                    if(round>0)Thread.sleep(5000);
                    List<Models.Instance> list=cloud.list();
                    Models.Instance current=Models.find(list,node);
                    main.post(()->applyList(list));
                    if(current!=null&&current.status().equals("active")&&current.power().equals("running")&&!current.ip().isEmpty()&&!current.ip().equals("0.0.0.0"))break;
                }
            } catch(Exception e) {
                String message=safe(e);
                main.post(()->{s.verified=false;s.message="创建未确认，请刷新后检查";log(node.name()+"："+message+"；写请求不会自动重发");});
            } finally { main.post(()->{s.busy=false;changed();startChecks();}); }
        });
    }
    void destroy(Models.Node node,String expectedId) {
        State s=states.get(node.id());if(demo||busy()||s.pending!=null)return;
        s.pending=new Models.Pending(expectedId,false);
        try {persistPending();}catch(Exception e){s.pending=null;log("未能保存操作记录，已取消销毁请求");changed();return;}
        s.busy=true;s.verified=false;s.message="正在核对云端实例并提交销毁…";changed();
        operations.execute(()->{
            try {
                cloud.destroy(node,expectedId);
                main.post(()->{s.pending=new Models.Pending(expectedId,true);s.message="销毁请求已受理，正在确认";try{persistPending();}catch(Exception e){log("本地操作记录保存失败");}log(node.name()+"：销毁请求已受理");changed();});
            } catch(Exception e) {
                String error=safe(e);
                // An interrupted write may already have reached the server. Query; never resend it.
                main.post(()->{
                    if(!(e instanceof Cloud.WriteUncertain)){s.pending=null;try{persistPending();}catch(Exception ignored){}}
                    s.message=s.pending==null?"销毁未提交，请刷新": "销毁结果待确认，请勿重复操作";
                    log(node.name()+"："+error);changed();
                });
            }
            for(int round=0;round<3;round++) {
                try {
                    List<Models.Instance> list=cloud.list();
                    Models.Instance found=Models.find(list,node);
                    main.post(()->applyList(list));
                    if(found==null||!found.id().equals(expectedId))break;
                } catch(Exception e) {
                    String error=safe(e);main.post(()->{fail(s,e);log(error);changed();});
                }
                if(round<2) try{Thread.sleep(4000);}catch(InterruptedException e){Thread.currentThread().interrupt();break;}
            }
            main.post(()->{s.busy=false;changed();});
        });
    }
    static String safe(Exception e) {
        if(e instanceof Cloud.ApiError||e instanceof java.io.IOException)return e.getMessage()==null?"网络请求失败":e.getMessage();
        if(e instanceof JSONException||e instanceof NumberFormatException)return "云端响应格式不完整，操作结果尚未确认";
        return e.getMessage()==null?"操作失败，请刷新确认":e.getMessage();
    }
}
