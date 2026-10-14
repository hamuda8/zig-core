package com.wufour.zui;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.util.Log;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import java.util.Map;
import org.json.JSONObject;

/**
 * Firebase Cloud Messaging for zui apps: the only class that touches Firebase. Compiled only for
 * apps built with `addApp(.android_push)`; everything else goes through ZuiPushHost (see there
 * for how a push reaches the app's Zig code, also when the app is not running).
 *
 * Firebase is initialised here by hand (no google-services plugin, no Gradle): the project id,
 * app id, API key and sender id come from the app's google-services.json at build time, as
 * `zui.fcm.*` meta-data in the merged manifest (tools/apk.zig).
 *
 * The app's manifest declares the service:
 *   <service android:name="com.wufour.zui.ZuiPush" android:exported="false">
 *     <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
 *   </service>
 * and POST_NOTIFICATIONS (asked for by fx.registerPush on Android 13+).
 *
 * Servers send data messages (no "notification" part) so that the app always decides what to
 * show; urgent ones (calls, dispatch alarms) with android.priority "high", which may start the
 * app's process when it is not running.
 */
public final class ZuiPush extends FirebaseMessagingService {
    /** Initialises Firebase from the manifest's values; false when the app has none. */
    static boolean init(Context c) {
        try {
            if (!FirebaseApp.getApps(c).isEmpty()) return true;
            Bundle m = c.getPackageManager().getApplicationInfo(c.getPackageName(), PackageManager.GET_META_DATA).metaData;
            String app = value(m, "zui.fcm.app_id"), key = value(m, "zui.fcm.api_key");
            String project = value(m, "zui.fcm.project_id"), sender = value(m, "zui.fcm.sender_id");
            if (app == null || key == null || project == null) {
                Log.w("zui", "push: no Firebase values in the manifest (google-services.json missing at build time)");
                return false;
            }
            FirebaseApp.initializeApp(c.getApplicationContext(), new FirebaseOptions.Builder()
                    .setApplicationId(app).setApiKey(key).setProjectId(project).setGcmSenderId(sender).build());
            return true;
        } catch (Exception e) {
            Log.e("zui", "push: " + e);
            return false;
        }
    }

    /** apk.zig writes "zui:<value>", so aapt2 keeps numbers as text. */
    static String value(Bundle m, String name) {
        Object v = m == null ? null : m.get(name);
        if (v == null) return null;
        String s = v.toString();
        return s.startsWith("zui:") ? s.substring(4) : s;
    }

    /** From ZuiPushHost.register (fx.registerPush): the current token. */
    public static void register(Context c) {
        if (!init(c)) return;
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(t -> {
            if (t.isSuccessful() && t.getResult() != null) ZuiPushHost.token(t.getResult());
            else Log.e("zui", "push: no token: " + t.getException());
        });
    }

    @Override
    public void onCreate() {
        init(this);
        super.onCreate();
    }

    @Override
    public void onNewToken(String token) {
        ZuiPushHost.token(token);
    }

    /** On Firebase's worker thread; returns once the app handled it. */
    @Override
    public void onMessageReceived(RemoteMessage message) {
        Map<String, String> data = message.getData();
        JSONObject json = new JSONObject();
        try {
            for (Map.Entry<String, String> e : data.entrySet()) json.put(e.getKey(), e.getValue());
        } catch (Exception e) {
            Log.e("zui", "push: " + e);
        }
        Log.i("zui", "push: message (" + data.size() + " fields, priority " + message.getPriority() + ")");
        ZuiPushHost.message(this, json.toString());
    }
}
