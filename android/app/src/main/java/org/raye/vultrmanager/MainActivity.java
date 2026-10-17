package org.raye.vultrmanager;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;

/** Native Android views; no embedded browser, remote UI, or third-party analytics. */
public final class MainActivity extends Activity {
    private static final int BG=0xfff5f7fb,INK=0xff18263f,MUTED=0xff7b879b,BLUE=0xff2463eb,NAVY=0xff234b9a,PALE=0xffedf3ff,GREEN=0xff218665,RED=0xffcc4453;
    private static final int CONFIG=10,KEY=11,EXPORT=12;
    private ManagerApp app;
    private LinearLayout root,body;
    private ScrollView scroll;
    private String tab="nodes",detail=null,renderKey="",stagedConfig=null,stagedKey=null,exportContent=null;
    private final List<TextView> clocks=new ArrayList<>();
    private final Map<TextView,Instant> clockTimes=new HashMap<>();
    private boolean showingLogs=false;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final Runnable tick=new Runnable(){public void run(){for(TextView v:clocks)v.setText(Models.age(clockTimes.get(v)));handler.postDelayed(this,1000);}};

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);app=(ManagerApp)getApplication();
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE|View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN|View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION|View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        // Handle Android 15's enforced edge-to-edge using actual system insets.
        getWindow().getDecorView().setOnApplyWindowInsetsListener((v,insets)->{
            if(root!=null)root.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            return insets.consumeSystemWindowInsets();
        });
        if(state!=null){tab=state.getString("tab","nodes");detail=state.getString("detail");}
        if(!app.configured)tab="settings";
        render();
        if(app.configured&&app.states.values().stream().allMatch(s->s.checked==null))app.refresh();
    }
    @Override protected void onSaveInstanceState(Bundle out){out.putString("tab",tab);out.putString("detail",detail);super.onSaveInstanceState(out);}
    @Override protected void onResume(){super.onResume();app.listener=this::render;render();handler.post(tick);}
    @Override protected void onPause(){super.onPause();app.listener=null;handler.removeCallbacks(tick);}
    @Override public void onBackPressed(){if(detail!=null||showingLogs){detail=null;showingLogs=false;render();}else if(!tab.equals("nodes")&&app.configured){tab="nodes";render();}else super.onBackPressed();}
    private int dp(float n){return (int)(getResources().getDisplayMetrics().density*n+.5f);}
    private GradientDrawable shape(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    private LinearLayout column(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);return l;}
    private LinearLayout row(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    private TextView text(String value,float size,int color,boolean bold){TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);t.setIncludeFontPadding(false);t.setLineSpacing(dp(3),1);if(bold)t.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));return t;}
    private void add(LinearLayout parent,View v,int top){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.topMargin=dp(top);parent.addView(v,p);}
    private void space(LinearLayout p,int h){View s=new View(this);p.addView(s,new LinearLayout.LayoutParams(1,dp(h)));}
    private TextView label(String value){return text(value,13,MUTED,false);}
    private LinearLayout card(LinearLayout parent,int color){LinearLayout c=column();c.setPadding(dp(20),dp(20),dp(20),dp(20));c.setBackground(shape(color,22));add(parent,c,14);return c;}
    private TextView button(String value,int bg,int fg,Runnable action){TextView b=text(value,15,fg,true);b.setGravity(Gravity.CENTER);b.setPadding(dp(14),dp(15),dp(14),dp(15));b.setMinHeight(dp(50));b.setBackground(shape(bg,14));b.setClickable(true);b.setFocusable(true);b.setOnClickListener(v->action.run());return b;}
    private void disable(View v,boolean disabled){v.setEnabled(!disabled);v.setAlpha(disabled?.4f:1f);}
    private void nav(String name,String key,String icon,LinearLayout container){LinearLayout item=column();item.setGravity(Gravity.CENTER);item.setPadding(0,dp(9),0,dp(8));int color=tab.equals(key)?BLUE:MUTED;Icon i=new Icon(icon,color);item.addView(i,new LinearLayout.LayoutParams(dp(23),dp(23)));TextView caption=text(name,11,color,tab.equals(key));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-2,-2);p.topMargin=dp(5);item.addView(caption,p);item.setContentDescription(name);item.setFocusable(true);item.setOnClickListener(v->{tab=key;detail=null;showingLogs=false;render();});container.addView(item,new LinearLayout.LayoutParams(0,-2,1));}
    private void header(String eyebrow,String title,boolean back,Runnable refresh){
        LinearLayout r=row(),words=column();
        if(back){TextView b=button("‹",0,INK,()->{detail=null;showingLogs=false;render();});b.setTextSize(28);r.addView(b,new LinearLayout.LayoutParams(dp(46),dp(50)));}
        else add(words,text(eyebrow,11,MUTED,true),0);
        add(words,text(title,27,INK,true),back?0:8);r.addView(words,new LinearLayout.LayoutParams(0,-2,1));
        if(refresh!=null){FrameLayout box=new FrameLayout(this);box.setBackground(shape(0xffffffff,50));Icon icon=new Icon("refresh",BLUE);FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(dp(22),dp(22),Gravity.CENTER);box.addView(icon,p);box.setContentDescription("刷新状态");box.setFocusable(true);box.setOnClickListener(v->refresh.run());r.addView(box,new LinearLayout.LayoutParams(dp(48),dp(48)));}
        add(body,r,0);
    }
    private void render(){
        if(isFinishing()||isDestroyed())return;
        String newKey=tab+":"+detail+":"+showingLogs;
        int oldY=newKey.equals(renderKey)&&scroll!=null?scroll.getScrollY():0;renderKey=newKey;
        clocks.clear();clockTimes.clear();
        root=column();root.setBackgroundColor(BG);
        scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);
        LinearLayout center=column();center.setGravity(Gravity.TOP|Gravity.CENTER_HORIZONTAL);
        body=column();body.setPadding(dp(22),dp(22),dp(22),dp(28));
        int maxWidth=Math.min(getResources().getDisplayMetrics().widthPixels,dp(620));center.addView(body,new LinearLayout.LayoutParams(maxWidth,-2));scroll.addView(center);
        root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        if(app.demo)add(body,text("演示界面 · 全部为模拟数据 · 不连接云端",12,RED,true),0);
        if(showingLogs)logs();else if(detail!=null&&app.configured)details();else if(tab.equals("account"))account();else if(tab.equals("settings"))settings();else home();
        if(detail==null&&!showingLogs){LinearLayout nav=row();nav.setBackgroundColor(0xffffffff);nav("节点","nodes","server",nav);nav("账户","account","wallet",nav);nav("设置","settings","settings",nav);root.addView(nav,new LinearLayout.LayoutParams(-1,-2));}
        setContentView(root);root.requestApplyInsets();scroll.post(()->scroll.scrollTo(0,oldY));
    }
    private void balanceCard(){
        LinearLayout c=card(body,NAVY);
        add(c,text("账户预计剩余",14,0xffc8dbff,false),0);
        LinearLayout r=row();r.setGravity(Gravity.BOTTOM);TextView amount=text(app.balance==null?"—":Models.money(app.balance.remaining()),42,0xffffffff,true);r.addView(amount);TextView usd=text("  USD",13,0xffc8dbff,true);r.addView(usd);add(c,r,13);
        add(c,text(app.balance==null?"导入配置后，刷新读取 Vultr 账户":"预存 $"+Models.money(app.balance.credit())+"    待结算 $"+Models.money(app.balance.pending()),13,0xffd9e6ff,false),16);
        add(body,label(app.accountBusy?"正在查询账户…":!app.accountError.isEmpty()&&app.configured?"账户："+app.accountError+(app.balance==null?"":"（上次金额已保留）"):app.balance==null?"所有地区共用账户余额":"全账户 · 更新于 "+Models.localTime(app.balance.checked())),8);
        if(app.balance!=null&&!app.accountError.isEmpty())add(body,label("上次成功查询："+Models.localTime(app.balance.checked())),5);
    }
    private void home(){
        header("VULTR / PERSONAL","我的节点",false,app::refresh);balanceCard();
        LinearLayout section=row();section.addView(text("云端节点",18,INK,true),new LinearLayout.LayoutParams(0,-2,1));long active=app.states.values().stream().filter(s->s.verified&&s.instance!=null&&s.pending==null&&s.instance.power().equals("running")).count();section.addView(label(active+" / "+app.nodes.size()+" 运行"));add(body,section,26);
        if(!app.configured){LinearLayout c=card(body,0xffffffff);add(c,text("先接入已有节点",20,INK,true),0);add(c,label("从电脑私下传入 nodes.json 和 vultr-api.key。不会重新创建服务器。"),10);add(c,button("导入本地配置",BLUE,0xffffffff,()->{tab="settings";render();}),20);return;}
        for(Models.Node n:app.nodes){ManagerApp.State s=app.states.get(n.id());LinearLayout c=card(body,0xffffffff);LinearLayout r=row();TextView region=text(n.region().equals("nrt")?"TYO":n.region().equals("lax")?"LA":n.region().toUpperCase(Locale.ROOT),14,BLUE,true);region.setGravity(Gravity.CENTER);region.setBackground(shape(PALE,14));r.addView(region,new LinearLayout.LayoutParams(dp(48),dp(48)));LinearLayout title=column();title.setPadding(dp(12),0,0,0);add(title,text(n.name(),18,INK,true),0);add(title,label(n.region()+" · "+n.plan()),5);r.addView(title,new LinearLayout.LayoutParams(0,-2,1));add(c,r,0);
            add(c,text(s.message,13,stateColor(s),true),16);
            if(s.instance!=null&&s.verified&&s.pending==null){add(c,label("已开时长"),17);clock(c,s.instance.created(),32);add(c,label(s.basic),10);}
            else if(s.pending!=null)add(c,label("正在等待 Vultr 确认；网络失败不会当作已销毁。可手动刷新。"),10);
            else if(s.instance==null&&s.verified)add(c,label("当前地区没有实例，不再产生该实例费用。"),10);
            TextView open=button(s.instance==null&&s.verified?"开节点":"查看详情",s.instance==null&&s.verified?BLUE:PALE,s.instance==null&&s.verified?0xffffffff:BLUE,()->{if(s.instance==null&&s.verified)confirmCreate(n);else {detail=n.id();render();}});add(c,open,18);disable(open,s.busy||app.refreshing||(s.instance==null&&s.verified&&(app.busy()||app.demo)));
        }
        TextView export=button("导出全部 FlClash 配置  ↗",0xffffffff,BLUE,()->export(app.nodes));add(body,export,18);
        add(body,label("时长从云端创建时间起算，包含关机期间。其他设备开关后，请刷新确认。"),14);
        if(app.refreshing)add(body,label("正在查询云端实例…"),12);
    }
    private int stateColor(ManagerApp.State s){return s.pending!=null?0xffad760e:!s.verified?0xffad760e:s.instance==null?MUTED:GREEN;}
    private void clock(LinearLayout c,Instant start,int size){TextView t=text(Models.age(start),size,BLUE,true);t.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));add(c,t,8);clocks.add(t);clockTimes.put(t,start);}
    private void details(){
        Models.Node n=app.nodes.stream().filter(x->x.id().equals(detail)).findFirst().orElse(app.nodes.get(0));ManagerApp.State s=app.states.get(n.id());
        header("","节点详情",true,null);add(body,text(n.name(),28,INK,true),24);add(body,text(s.message,14,stateColor(s),true),10);
        LinearLayout time=card(body,PALE);add(time,text("已开时长",14,BLUE,true),0);clock(time,s.verified&&s.pending==null&&s.instance!=null?s.instance.created():null,40);add(time,label("自云端创建起算，包含关机期间"),12);
        LinearLayout health=card(body,0xffffffff);add(health,text("基础连接检查",16,INK,true),0);add(health,text(s.basic,14,BLUE,false),12);add(health,label("域名与 TCP 443 检查不代表完整代理访问已验证。"),10);
        LinearLayout info=card(body,0xffffffff);kv(info,"地区 / 套餐",n.region()+" / "+n.plan());kv(info,"云端状态",s.instance==null?"—":s.instance.status()+" / "+s.instance.power());kv(info,"创建时间",s.instance==null?"—":Models.localTime(s.instance.created()));kv(info,"固定域名",n.domain());kv(info,"公网 IP",s.instance==null?"—":s.instance.ip());kv(info,"实例 ID",s.instance==null?"—":s.instance.id());kv(info,"上次云端确认",Models.localTime(s.checked));
        add(body,button("导出此节点配置",BLUE,0xffffffff,()->export(Collections.singletonList(n))),20);
        TextView refresh=button(app.refreshing?"正在刷新…":"刷新状态",0xffffffff,BLUE,app::refresh);add(body,refresh,10);disable(refresh,app.refreshing||s.busy);
        TextView operation=button(s.pending!=null?"销毁结果待确认":s.instance==null?"开节点":"销毁节点",s.instance==null?PALE:0xffffebee,s.instance==null?BLUE:RED,()->{if(s.instance==null)confirmCreate(n);else confirmDestroy(n,s.instance);});add(body,operation,22);disable(operation,app.busy()||s.pending!=null||!s.verified||app.demo);
        add(body,label("销毁会影响所有正在使用该节点的电脑和手机。关闭此 App 不会关闭节点。"),12);
    }
    private void kv(LinearLayout c,String name,String value){add(c,label(name),12);TextView v=text(value,14,INK,false);v.setTextIsSelectable(true);add(c,v,6);}
    private void account(){header("VULTR / ACCOUNT","我的账户",false,app::refreshBalance);balanceCard();
        LinearLayout link=card(body,0xffffffff);LinearLayout row=row();LinearLayout words=column();add(words,text("打开 Vultr 控制台  ↗",17,INK,true),0);add(words,label("查看账单、充值与更多设置"),7);row.addView(words,new LinearLayout.LayoutParams(0,-2,1));row.addView(new Icon("external",BLUE),new LinearLayout.LayoutParams(dp(24),dp(24)));add(link,row,0);link.setFocusable(true);link.setContentDescription("打开 Vultr 控制台，在浏览器查看账单和充值");link.setOnClickListener(v->openWeb("https://my.vultr.com/"));
        LinearLayout c=card(body,0xffffffff);add(c,text("余额明细",18,INK,true),0);kv(c,"账户预存（USD）",app.balance==null?"—":Models.money(app.balance.credit()));kv(c,"待结算费用（USD）",app.balance==null?"—":Models.money(app.balance.pending()));kv(c,"预计剩余（USD）",app.balance==null?"—":Models.money(app.balance.remaining()));
        add(body,label("预计剩余 = 预存 − 待结算费用。所有地区共用，金额可能滞后；以 Vultr 实际账单为准。负数表示已超出预存。"),18);
        TextView refresh=button(app.accountBusy?"正在查询…":"刷新余额",BLUE,0xffffffff,app::refreshBalance);add(body,refresh,20);disable(refresh,app.accountBusy||!app.configured||app.demo);
    }
    private void settings(){header("VULTR / SETTINGS","设置",false,null);
        if(!app.setupError.isEmpty())add(body,text(app.setupError,14,RED,false),20);
        LinearLayout c=card(body,0xffffffff);add(c,text(app.configured?"已接入 "+app.nodes.size()+" 个地区":"接入已有云端节点",20,INK,true),0);add(c,label("从电脑私下传入两个文件，分别选择后保存。密钥只在手机本地加密保存。"),10);
        TextView config=button(stagedConfig==null?"① 选择 nodes.json":"① 配置已选择 ✓",PALE,BLUE,()->pick(CONFIG));add(c,config,18);
        TextView key=button(stagedKey==null?"② 选择 vultr-api.key":"② 密钥已选择 ✓",PALE,BLUE,()->pick(KEY));add(c,key,10);
        TextView save=button("保存并连接",BLUE,0xffffffff,()->{try{if(app.busy()||app.hasPending())throw new Exception("请先完成当前操作和销毁确认");app.install(stagedConfig,stagedKey);stagedConfig=null;stagedKey=null;tab="nodes";render();}catch(Exception e){notice("导入未完成",ManagerApp.safe(e));}});add(c,save,16);disable(save,stagedConfig==null||stagedKey==null||app.busy()||app.hasPending());disable(config,app.busy()||app.hasPending());disable(key,app.busy()||app.hasPending());
        add(body,label("导入不会新建服务器。手机与两台电脑管理同一组节点，不要同时操作同一地区。请避免把这两个文件发到公开聊天或网盘。"),14);
        LinearLayout network=card(body,0xffffffff);add(network,text("网络与 FlClash",18,INK,true),0);add(network,label("此 App 负责管理，不提供代理连接。导出的 YAML 请导入手机 FlClash。\n\n请使用规则模式，并保留 api.vultr.com 和管理 DNS 的直连规则；也可在 FlClash 的应用分流中将本 App 排除代理。VPN / TUN 仍可能接管网络，单靠 App 不能保证绕过。\n\n销毁手机当前使用的节点会中断 GPT 等代理连接；请先切换到另一可用节点。"),12);
        add(body,button("查看操作记录",0xffffffff,INK,()->{showingLogs=true;render();}),18);
        add(body,button("下载新版 APK  ↗",0xffffffff,BLUE,()->openWeb("https://github.com/rrrayyyyye/vultr-node-manager/releases/latest")),10);
        add(body,label("版本 "+BuildConfig.VERSION_NAME+" · Android 8.0 及以上\n更新：用有仓库权限的 GitHub 账号登录浏览器，下载新版覆盖安装。保留手机配置，请勿先卸载。"),12);
        if(app.configured){add(body,button("清除本机配置",0xffffebee,RED,()->new AlertDialog.Builder(this).setTitle("清除本机配置？").setMessage("只删除手机上的密钥和配置，不会销毁云端服务器。卸载或清除后需要重新导入。").setNegativeButton("取消",null).setPositiveButton("清除",(d,w)->{try{app.clear();render();}catch(Exception e){notice("无法清除",e.getMessage());}}).show()),22);}
    }
    private void logs(){header("","操作记录",true,null);add(body,label("仅保留本次应用进程最近 100 条记录，不保存 API 密钥或连接凭据。"),20);LinearLayout c=card(body,0xffffffff);TextView log=text(app.journal.isEmpty()?"暂无记录":String.join("\n\n",app.journal),13,INK,false);log.setTextIsSelectable(true);add(c,log,0);}
    private void confirmCreate(Models.Node n){if(app.demo||app.busy())return;new AlertDialog.Builder(this).setTitle("创建"+n.name()+"节点？").setMessage("套餐："+n.plan()+"\n将使用已有初始化脚本和域名。创建后 Vultr 开始计费；其他设备可能同时操作，请先确认。").setNegativeButton("取消",null).setPositiveButton("确认创建",(d,w)->app.create(n)).show();}
    private void confirmDestroy(Models.Node n,Models.Instance target){
        if(app.demo||app.busy())return;
        Dialog dialog=new Dialog(this);LinearLayout sheet=column();sheet.setPadding(dp(24),dp(26),dp(24),dp(28));sheet.setBackground(shape(0xffffffff,26));Icon trash=new Icon("trash",RED);sheet.addView(trash,new LinearLayout.LayoutParams(dp(38),dp(38)));add(sheet,text("销毁"+n.name()+"节点？",24,INK,true),20);add(sheet,text("这会永久删除云服务器及其数据。所有正在使用此节点的电脑和手机都会断开。",15,MUTED,false),14);LinearLayout summary=card(sheet,BG);add(summary,text(n.region()+" · "+n.plan(),14,INK,true),0);add(summary,label("已开时长 "+Models.age(target.created())),8);LinearLayout buttons=row();TextView cancel=button("暂不销毁",BG,INK,dialog::dismiss),confirm=button("确认销毁",RED,0xffffffff,()->{dialog.dismiss();app.destroy(n,target.id());});buttons.addView(cancel,new LinearLayout.LayoutParams(0,-2,1));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(12);buttons.addView(confirm,p);add(sheet,buttons,24);dialog.setContentView(sheet);Window window=dialog.getWindow();if(window!=null){window.setBackgroundDrawableResource(android.R.color.transparent);window.setLayout(-1,-2);window.setGravity(Gravity.BOTTOM);window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);WindowManager.LayoutParams attrs=window.getAttributes();attrs.dimAmount=.35f;window.setAttributes(attrs);}dialog.show();if(window!=null)window.setLayout(-1,-2);
    }
    private void pick(int code){Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);try{startActivityForResult(intent,code);}catch(ActivityNotFoundException e){notice("无法选文件","手机没有可用的系统文件选择器");}}
    private void export(List<Models.Node> nodes){if(nodes.isEmpty())return;new AlertDialog.Builder(this).setTitle("导出连接配置").setMessage("文件含节点连接凭据，请私下保存。可导入 FlClash；它不包含 Vultr API 密钥。").setNegativeButton("取消",null).setPositiveButton("选择保存位置",(d,w)->{exportContent=Models.exportYaml(nodes);Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/octet-stream").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,"vultr-"+(nodes.size()==1?nodes.get(0).id():"multi-region")+".yaml");try{startActivityForResult(intent,EXPORT);}catch(ActivityNotFoundException e){exportContent=null;notice("无法保存","手机没有可用的系统文件选择器");}}).show();}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null||data.getData()==null){if(request==EXPORT)exportContent=null;return;}Uri uri=data.getData();
        try{
            if(request==EXPORT){if(exportContent==null)throw new Exception("导出已中断，请重新选择导出");try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException("无法写入文件");out.write(exportContent.getBytes(StandardCharsets.UTF_8));}exportContent=null;new AlertDialog.Builder(this).setTitle("配置已保存").setMessage("在 FlClash 中从文件导入，选择规则模式和要使用的节点。可达性仍需在客户端实际验证。").setNegativeButton("完成",null).setPositiveButton("分享 / 打开",(d,w)->{Intent share=new Intent(Intent.ACTION_SEND).setType("application/octet-stream").putExtra(Intent.EXTRA_STREAM,uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);try{startActivity(Intent.createChooser(share,"私下导入配置"));}catch(ActivityNotFoundException e){notice("配置已保存","请在 FlClash 内选择刚保存的文件");}}).show();}
            else if(request==CONFIG||request==KEY){String raw;try(InputStream in=getContentResolver().openInputStream(uri)){if(in==null)throw new IOException("无法读取文件");raw=Cloud.readLimited(in,request==KEY?4096:256*1024);}if(request==CONFIG){Models.parseConfig(raw);stagedConfig=raw;}else stagedKey=Models.parseKey(raw);render();}
        }catch(Exception e){exportContent=null;notice("文件操作未完成",e instanceof org.json.JSONException?"配置不是有效的 nodes.json":ManagerApp.safe(e));}
    }
    private void openWeb(String url){try{startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(url)));}catch(ActivityNotFoundException e){notice("无法打开网页","请先安装或启用浏览器");}}
    private void notice(String title,String message){new AlertDialog.Builder(this).setTitle(title).setMessage(message).setPositiveButton("知道了",null).show();}

    private final class Icon extends View {
        private final String type;private final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);private final int color;
        Icon(String t,int c){super(MainActivity.this);type=t;color=c;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        protected void onDraw(Canvas canvas){super.onDraw(canvas);canvas.save();canvas.scale(getWidth()/24f,getHeight()/24f);p.setColor(color);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.7f);p.setStrokeCap(Paint.Cap.ROUND);p.setStrokeJoin(Paint.Join.ROUND);
            if(type.equals("server")){canvas.drawRoundRect(3,3,21,10,2,2,p);canvas.drawRoundRect(3,14,21,21,2,2,p);canvas.drawPoint(7,6.5f,p);canvas.drawPoint(7,17.5f,p);}
            else if(type.equals("wallet")){canvas.drawRoundRect(3,5,21,20,3,3,p);canvas.drawRoundRect(14,10,22,16,1,1,p);canvas.drawLine(4,5,18,2,p);}
            else if(type.equals("refresh")){canvas.drawArc(4,4,20,20,40,290,false,p);canvas.drawLine(20,4,20,10,p);canvas.drawLine(14,10,20,10,p);}
            else if(type.equals("external")){canvas.drawLine(13,3,21,3,p);canvas.drawLine(21,3,21,11,p);canvas.drawLine(11,13,21,3,p);canvas.drawLine(9,5,4,5,p);canvas.drawLine(4,5,4,21,p);canvas.drawLine(4,21,20,21,p);canvas.drawLine(20,21,20,16,p);}
            else if(type.equals("trash")){canvas.drawLine(3,6,21,6,p);canvas.drawLine(8,3,16,3,p);canvas.drawLine(6,6,7,21,p);canvas.drawLine(7,21,17,21,p);canvas.drawLine(17,21,18,6,p);canvas.drawLine(10,10,10,17,p);canvas.drawLine(14,10,14,17,p);}
            else {canvas.drawCircle(12,12,7,p);canvas.drawCircle(12,12,2.5f,p);for(int a=0;a<8;a++){canvas.save();canvas.rotate(a*45,12,12);canvas.drawLine(12,2,12,5,p);canvas.restore();}}
            canvas.restore();
        }
    }
}
