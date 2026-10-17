package org.raye.vultrmanager;

import android.app.*;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.*;
import android.view.*;
import android.widget.TextView;
import java.io.*;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.*;

/** Runs on an isolated emulator. All displayed values are synthetic; no API client is created. */
public final class SmokeRunner extends Instrumentation {
    @Override public void onCreate(Bundle arguments){super.onCreate(arguments);start();}
    @Override public void onStart(){
        Bundle result=new Bundle();
        try {
            ManagerApp app=(ManagerApp)getTargetContext().getApplicationContext();
            Models.Node la=new Models.Node("los-angeles","洛杉矶（北美）","LA-demo","lax","demo-la","la.example.invalid","demo-script","vc2-1c-1gb",2284,"00000000-0000-0000-0000-000000000000","A".repeat(43),"aabb","www.example.com");
            Models.Node tokyo=new Models.Node("tokyo","东京","Tokyo-demo","nrt","demo-tokyo","tokyo.example.invalid","demo-script","vc2-1c-1gb",2284,la.uuid(),la.publicKey(),"ccdd",la.sni());
            runOnMainSync(()->{app.demo=true;app.configured=true;app.nodes=List.of(la,tokyo);ManagerApp.State s=new ManagerApp.State();s.verified=true;s.checked=Instant.now();s.instance=new Models.Instance("demo-instance","lax","demo-la","active","running","192.0.2.1",Instant.now().minusSeconds(8076));s.message="运行中";s.basic="域名 一致 · TCP 443 可达";app.states.put(la.id(),s);ManagerApp.State t=new ManagerApp.State();t.verified=true;t.checked=Instant.now();t.message="未创建 / 已销毁";app.states.put(tokyo.id(),t);app.balance=new Models.Balance(new BigDecimal("10"),new BigDecimal("0.60"),new BigDecimal("9.40"),Instant.now());app.accountError="";});
            Activity activity=startActivitySync(new Intent(getTargetContext(),MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitForIdleSync();Thread.sleep(1000);assertText(activity,"我的节点");screenshot("android-native-home.png");
            click(activity,"查看详情");Thread.sleep(600);assertText(activity,"节点详情");screenshot("android-native-detail.png");
            runOnMainSync(activity::onBackPressed);waitForIdleSync();click(activity,"账户");Thread.sleep(600);assertText(activity,"打开 Vultr 控制台  ↗");screenshot("android-native-account.png");
            click(activity,"设置");Thread.sleep(600);assertText(activity,"保存并连接");screenshot("android-native-settings.png");
            // Exercise Keystore storage with fake values, then remove it.
            Vault vault=new Vault(getTargetContext());org.json.JSONObject fake=new org.json.JSONObject().put("key","synthetic-emulator-test-value");vault.save(fake);if(!fake.toString().equals(vault.load().toString()))throw new AssertionError("Encrypted store roundtrip failed");vault.clear();
            result.putString("stream","Native UI, navigation and encrypted storage smoke checks passed (synthetic data only).\n");finish(Activity.RESULT_OK,result);
        }catch(Throwable e){result.putString("stream","Smoke check failed: "+e.getClass().getSimpleName()+": "+e.getMessage());finish(Activity.RESULT_CANCELED,result);}
    }
    private TextView find(View v,String label){if(v instanceof TextView&&((TextView)v).getText().toString().equals(label))return(TextView)v;if(v instanceof ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++){TextView found=find(g.getChildAt(i),label);if(found!=null)return found;}}return null;}
    private void assertText(Activity a,String label){runOnMainSync(()->{if(find(a.getWindow().getDecorView(),label)==null)throw new AssertionError("Missing UI: "+label);});}
    private void click(Activity a,String label){runOnMainSync(()->{TextView v=find(a.getWindow().getDecorView(),label);if(v==null)throw new AssertionError("Missing action: "+label);View target=v;while(!target.isClickable()&&target.getParent() instanceof View)target=(View)target.getParent();target.performClick();});waitForIdleSync();}
    private void screenshot(String filename)throws Exception{Bitmap b=getUiAutomation().takeScreenshot();if(b==null)throw new AssertionError("Screenshot unavailable");try(OutputStream out=new FileOutputStream(new File(getTargetContext().getExternalFilesDir(null),filename))){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();}
}
