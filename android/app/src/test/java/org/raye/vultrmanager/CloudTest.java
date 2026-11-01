package org.raye.vultrmanager;

import org.junit.Test;
import org.json.*;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.*;
import static org.junit.Assert.*;

public class CloudTest {
    @Test public void ipv6NodeUsesV6AddressAndCreateFlag() throws Exception {
        Models.Node n=new Models.Node("atl-v6","Atlanta","ATL-test","atl","atl-test","atl.invalid","script-test","vc2-1c-0.5gb-v6",2136,"00000000-0000-0000-0000-000000000000","A".repeat(43),"aabb","www.example.com");
        JSONObject row=instance("v6-id","atl","atl-test").put("main_ip","100.64.0.1").put("v6_main_ip","2001:db8::1");
        Mock api=new Mock(page(null),new JSONObject().put("available_plans",new JSONArray().put(n.plan())),new JSONObject().put("startup_script",new JSONObject()),page(null),new JSONObject().put("instance",row));
        assertEquals("2001:db8::1",new Cloud(api).create(n).ip());
        assertTrue(api.lastBody.getBoolean("enable_ipv6"));
        assertEquals(2136,api.lastBody.getInt("os_id"));
        assertEquals("2001:db8::1",Models.find(List.of(Models.instance(row)),n).ip());
        assertTrue(Cloud.sameIp("2001:0db8:0:0:0:0:0:1","2001:db8::1"));
        assertFalse(Cloud.sameIp("example.invalid","2001:db8::1"));
        String yaml=Models.exportYaml(List.of(TOKYO,n));
        assertTrue(yaml.contains("ipv6: true"));assertTrue(yaml.contains("  ipv6: true"));
        assertTrue(yaml.contains("ip-version: ipv6"));assertTrue(yaml.contains("ip-version: ipv4"));
        assertTrue(Models.parseConfig(config(n)).get(0).ipv6());
    }
    static final Models.Node TOKYO=new Models.Node("tokyo","东京","Tokyo-test","nrt","tokyo-test","tokyo.invalid","script-test","vc2-1c-1gb",2284,"00000000-0000-0000-0000-000000000000","A".repeat(43),"aabb","www.example.com");
    static JSONObject instance(String id,String region,String label) throws Exception {return new JSONObject().put("id",id).put("region",region).put("label",label).put("status","active").put("power_status","running").put("main_ip","192.0.2.1").put("date_created","2026-10-17 00:00:00");}
    static JSONObject page(String next,JSONObject...rows) throws Exception {return new JSONObject().put("instances",new JSONArray(Arrays.asList(rows))).put("meta",new JSONObject().put("links",new JSONObject().put("next",next==null?JSONObject.NULL:next)));}
    static final class Mock implements Cloud.Transport {
        final Queue<Object> replies=new ArrayDeque<>();final List<String> calls=new ArrayList<>();JSONObject lastBody;
        Mock(Object...r){replies.addAll(Arrays.asList(r));}
        public JSONObject request(String method,String path,JSONObject body,int timeout)throws Exception {calls.add(method+" "+path);lastBody=body;if(replies.isEmpty())throw new AssertionError("Unexpected request: "+method+" "+path);Object reply=replies.remove();if(reply instanceof Exception)throw (Exception)reply;return (JSONObject)reply;}
    }
    @Test public void completePaginationFindsRemoteNode()throws Exception{Mock api=new Mock(page("cursor+two"),page(null,instance("id-1","nrt","tokyo-test")));List<Models.Instance> list=new Cloud(api).list();assertEquals("id-1",Models.find(list,TOKYO).id());assertTrue(api.calls.get(1).contains("cursor%2Btwo"));}
    @Test public void successfulEmptyListMeansDestroyed()throws Exception{assertNull(Models.find(new Cloud(new Mock(page(null))).list(),TOKYO));}
    @Test public void apiFailureDoesNotMeanDestroyed()throws Exception{try{new Cloud(new Mock(new java.io.IOException("offline"))).list();fail();}catch(java.io.IOException expected){assertEquals("offline",expected.getMessage());}}
    @Test public void incompletePaginationIsRejected()throws Exception{try{new Cloud(new Mock(new JSONObject().put("instances",new JSONArray()))).list();fail();}catch(JSONException expected){}}
    @Test public void repeatedCursorIsRejected()throws Exception{try{new Cloud(new Mock(page("a"),page("a"))).list();fail();}catch(Exception expected){assertTrue(expected.getMessage().contains("游标"));}}
    @Test public void duplicateLabelsBlockDelete()throws Exception{Mock api=new Mock(page(null,instance("one","nrt","tokyo-test"),instance("two","nrt","tokyo-test")));try{new Cloud(api).destroy(TOKYO,"one");fail();}catch(Exception expected){assertTrue(expected.getMessage().contains("重复标签"));}assertEquals(1,api.calls.size());}
    @Test public void wrongRegionBlocksDelete()throws Exception{Mock api=new Mock(page(null,instance("one","lax","tokyo-test")));try{new Cloud(api).destroy(TOKYO,"one");fail();}catch(Exception expected){assertTrue(expected.getMessage().contains("其他地区"));}assertEquals(1,api.calls.size());}
    @Test public void recreatedInstanceNeverDeleted()throws Exception{Mock api=new Mock(page(null,instance("new-id","nrt","tokyo-test")));try{new Cloud(api).destroy(TOKYO,"old-id");fail();}catch(Exception expected){assertTrue(expected.getMessage().contains("替换"));}assertEquals(1,api.calls.size());}
    @Test public void deleteUsesExactIdOnce()throws Exception{Mock api=new Mock(page(null,instance("exact-id","nrt","tokyo-test")),new JSONObject());new Cloud(api).destroy(TOKYO,"exact-id");assertEquals(List.of("GET /instances?per_page=100","DELETE /instances/exact-id"),api.calls);}
    @Test public void failedWriteNeverRetried()throws Exception{Mock api=new Mock(page(null,instance("id","nrt","tokyo-test")),new java.io.IOException("interrupted"));try{new Cloud(api).destroy(TOKYO,"id");fail();}catch(Cloud.WriteUncertain expected){}assertEquals(2,api.calls.size());}
    @Test public void definiteRejectionIsNotAnAcceptedDeletion()throws Exception{Mock api=new Mock(page(null,instance("id","nrt","tokyo-test")),new Cloud.ApiError(403));try{new Cloud(api).destroy(TOKYO,"id");fail();}catch(Cloud.ApiError expected){assertEquals(403,expected.status);}assertEquals(2,api.calls.size());}
    @Test public void createReusesExistingNode()throws Exception{Mock api=new Mock(page(null,instance("existing","nrt","tokyo-test")));assertEquals("existing",new Cloud(api).create(TOKYO).id());assertEquals(1,api.calls.size());}
    @Test public void createRechecksBeforeWriting()throws Exception{Mock api=new Mock(page(null),new JSONObject().put("available_plans",new JSONArray().put(TOKYO.plan())),new JSONObject().put("startup_script",new JSONObject()),page(null,instance("other-host","nrt","tokyo-test")));assertEquals("other-host",new Cloud(api).create(TOKYO).id());assertFalse(api.calls.stream().anyMatch(s->s.startsWith("POST")));}
    @Test public void createPayloadIsRegionScoped()throws Exception{Mock api=new Mock(page(null),new JSONObject().put("available_plans",new JSONArray().put(TOKYO.plan())),new JSONObject().put("startup_script",new JSONObject()),page(null),new JSONObject().put("instance",instance("new","nrt","tokyo-test")));new Cloud(api).create(TOKYO);assertEquals("nrt",api.lastBody.getString("region"));assertEquals("script-test",api.lastBody.getString("script_id"));assertFalse(api.lastBody.getBoolean("enable_ipv6"));}
    @Test public void balanceUsesSignedLedgerAndPending()throws Exception{Models.Balance b=Models.balance(new JSONObject("{\"account\":{\"balance\":-10,\"pending_charges\":0.27}}"));assertEquals(new BigDecimal("9.73"),b.remaining());Models.Balance debt=Models.balance(new JSONObject("{\"account\":{\"balance\":2,\"pending_charges\":0.5}}"));assertEquals(new BigDecimal("-2.5"),debt.remaining());}
    @Test public void missingOrNegativePendingRejected()throws Exception{for(String raw:List.of("{\"account\":{\"balance\":-10}}","{\"account\":{\"balance\":-10,\"pending_charges\":-1}}")){try{Models.balance(new JSONObject(raw));fail();}catch(Exception expected){}}}
    @Test public void timesAreUTCAndInvalidDatesDoNotInventAge()throws Exception{assertEquals(Instant.parse("2026-10-17T00:00:00Z"),Models.instance(instance("one","nrt","tokyo-test")).created());assertNull(Models.instance(instance("one","nrt","tokyo-test").put("date_created","bad")).created());assertEquals("—",Models.age(null));}
    @Test public void exportHasManagementDirectRulesBeforeProxy() {String yaml=Models.exportYaml(List.of(TOKYO));assertTrue(yaml.contains("mode: rule"));assertTrue(yaml.indexOf("DOMAIN,api.vultr.com,DIRECT")<yaml.indexOf("MATCH,PROXY"));assertTrue(yaml.contains("short-id: 'aabb'"));assertFalse(yaml.contains("Authorization"));assertFalse(yaml.contains("script-test"));}
    @Test public void importValidatesDuplicatesAndTemplates()throws Exception{String config=config(TOKYO);assertEquals(1,Models.parseConfig(config).size());try{Models.parseConfig(config.replace("\"tokyo.invalid\"","\"YOUR_DOMAIN\""));fail();}catch(Exception expected){}JSONObject root=new JSONObject(config);root.getJSONArray("nodes").put(root.getJSONArray("nodes").get(0));try{Models.parseConfig(root.toString());fail();}catch(Exception expected){assertTrue(expected.getMessage().contains("唯一"));}}
    static String config(Models.Node n)throws Exception{return new JSONObject().put("version",1).put("nodes",new JSONArray().put(new JSONObject().put("id",n.id()).put("name",n.name()).put("linkName",n.linkName()).put("region",n.region()).put("label",n.label()).put("domain",n.domain()).put("startupScriptId",n.script()).put("plan",n.plan()).put("osId",n.osId()).put("uuid",n.uuid()).put("publicKey",n.publicKey()).put("shortId",n.shortId()).put("sni",n.sni()))).toString();}
}
