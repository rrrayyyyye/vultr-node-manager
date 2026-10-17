package org.raye.vultrmanager;

import android.content.Context;
import android.security.keystore.*;
import android.util.Base64;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Encrypted settings in app-private storage. Encryption key never leaves Android Keystore. */
final class Vault {
    private final Context context;
    private static final String ALIAS="vultr-manager-local-v1";
    Vault(Context c) { context=c; }
    private javax.crypto.SecretKey key() throws Exception {
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        if(!ks.containsAlias(ALIAS)) {
            KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return (javax.crypto.SecretKey)ks.getKey(ALIAS,null);
    }
    JSONObject load() throws Exception {
        String saved=context.getSharedPreferences("vault",Context.MODE_PRIVATE).getString("data",null);
        if(saved==null) return new JSONObject();
        JSONObject envelope=new JSONObject(saved);
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(envelope.getString("iv"),Base64.NO_WRAP)));
        return new JSONObject(new String(cipher.doFinal(Base64.decode(envelope.getString("cipher"),Base64.NO_WRAP)),StandardCharsets.UTF_8));
    }
    void save(JSONObject data) throws Exception {
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key());
        JSONObject envelope=new JSONObject().put("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP))
            .put("cipher",Base64.encodeToString(cipher.doFinal(data.toString().getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP));
        if(!context.getSharedPreferences("vault",Context.MODE_PRIVATE).edit().putString("data",envelope.toString()).commit()) throw new Exception("本地加密保存失败");
    }
    void clear() throws Exception {
        if(!context.getSharedPreferences("vault",Context.MODE_PRIVATE).edit().clear().commit()) throw new Exception("本地删除失败");
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore"); ks.load(null); ks.deleteEntry(ALIAS);
    }
}
