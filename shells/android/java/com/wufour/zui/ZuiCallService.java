package com.wufour.zui;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.ConnectionService;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telecom.VideoProfile;
import java.util.HashMap;

/**
 * Calls the phone itself knows about: a self-managed ConnectionService (so Bluetooth, the car and
 * other calling apps see the call) and a ringing CallStyle notification with a full-screen intent,
 * which lights up a locked phone. The app's manifest declares:
 *   <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
 *   <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
 *   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
 *   <service android:name="com.wufour.zui.ZuiCallService" android:exported="true"
 *       android:permission="android.permission.BIND_TELECOM_CONNECTION_SERVICE">
 *     <intent-filter><action android:name="android.telecom.ConnectionService" /></intent-filter>
 *   </service>
 *   <receiver android:name="com.wufour.zui.ZuiCallReceiver" android:exported="false" />
 * Events go to the app's Zig code through Zui.callEvent.
 */
public final class ZuiCallService extends ConnectionService {
    static final String EXTRA_ID = "zui_call_id", EXTRA_NAME = "zui_call_name", EXTRA_VIDEO = "zui_call_video";
    static final String EXTRA_ANSWER = "zui_call_answer";
    static final String CHANNEL = "zui_calls";
    static final int ANSWER = 1, DECLINE = 2, END = 3;
    static final HashMap<String, Call> calls = new HashMap<>();

    static final class Call extends Connection {
        final Context context;
        final String id, name;
        final boolean video, incoming;
        boolean ended;

        Call(Context context, String id, String name, boolean video, boolean incoming) {
            this.context = context.getApplicationContext();
            this.id = id;
            this.name = name;
            this.video = video;
            this.incoming = incoming;
            setConnectionProperties(PROPERTY_SELF_MANAGED);
            setConnectionCapabilities(CAPABILITY_MUTE | CAPABILITY_SUPPORT_HOLD);
            setAudioModeIsVoip(true);
            setAddress(Uri.fromParts("zui", id, null), TelecomManager.PRESENTATION_ALLOWED);
            setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED);
            setVideoState(video ? VideoProfile.STATE_BIDIRECTIONAL : VideoProfile.STATE_AUDIO_ONLY);
        }

        @Override
        public void onShowIncomingCallUi() {
            showRinging(context, id, name, video);
        }

        @Override
        public void onAnswer() {
            answered(context, id);
        }

        @Override
        public void onAnswer(int videoState) {
            answered(context, id);
        }

        @Override
        public void onReject() {
            finish(new DisconnectCause(DisconnectCause.REJECTED), DECLINE);
        }

        @Override
        public void onDisconnect() {
            finish(new DisconnectCause(DisconnectCause.LOCAL), END);
        }

        @Override
        public void onAbort() {
            finish(new DisconnectCause(DisconnectCause.CANCELED), END);
        }

        void finish(DisconnectCause cause, int event) {
            if (ended) return;
            ended = true;
            calls.remove(id);
            cancelRinging(context, id);
            setDisconnected(cause);
            destroy();
            if (event != 0) Zui.callEvent(event, id);
        }
    }

    static PhoneAccountHandle account(Context c) {
        return new PhoneAccountHandle(new ComponentName(c, ZuiCallService.class), "zui");
    }

    static TelecomManager telecom(Context c) {
        TelecomManager tm = c.getSystemService(TelecomManager.class);
        CharSequence label = c.getApplicationInfo().loadLabel(c.getPackageManager());
        tm.registerPhoneAccount(PhoneAccount.builder(account(c), label)
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED | PhoneAccount.CAPABILITY_VIDEO_CALLING | PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING)
                .build());
        return tm;
    }

    static Bundle extras(String id, String name, boolean video) {
        Bundle b = new Bundle();
        b.putString(EXTRA_ID, id);
        b.putString(EXTRA_NAME, name);
        b.putBoolean(EXTRA_VIDEO, video);
        return b;
    }

    /** An incoming call. Without telecom (another call is on, or it refused) it still rings. */
    static void ring(Context c, String id, String name, boolean video) {
        if (calls.containsKey(id)) return;
        try {
            TelecomManager tm = telecom(c);
            if (tm.isIncomingCallPermitted(account(c))) {
                Bundle b = new Bundle();
                b.putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, extras(id, name, video));
                if (video) b.putInt(TelecomManager.EXTRA_INCOMING_VIDEO_STATE, VideoProfile.STATE_BIDIRECTIONAL);
                tm.addNewIncomingCall(account(c), b);
                return;
            }
        } catch (RuntimeException e) {
            android.util.Log.e("zui", "telecom: " + e);
        }
        showRinging(c, id, name, video);
    }

    static void outgoing(Context c, String id, String name, boolean video) {
        if (calls.containsKey(id)) return;
        try {
            TelecomManager tm = telecom(c);
            Bundle b = new Bundle();
            b.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account(c));
            b.putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, extras(id, name, video));
            if (video) b.putInt(TelecomManager.EXTRA_START_CALL_WITH_VIDEO_STATE, VideoProfile.STATE_BIDIRECTIONAL);
            tm.placeCall(Uri.fromParts("zui", id, null), b);
        } catch (RuntimeException e) {
            android.util.Log.e("zui", "telecom: " + e);
        }
    }

    static void connected(String id) {
        Call call = calls.get(id);
        if (call != null) call.setActive();
    }

    /** The app ended it (hung up, the caller gave up, answered elsewhere). */
    static void end(Context c, String id) {
        Call call = calls.get(id);
        if (call != null) call.finish(new DisconnectCause(DisconnectCause.LOCAL), 0);
        cancelRinging(c, id);
    }

    static void decline(Context c, String id) {
        Call call = calls.get(id);
        if (call != null) call.finish(new DisconnectCause(DisconnectCause.REJECTED), DECLINE);
        else {
            cancelRinging(c, id);
            Zui.callEvent(DECLINE, id);
        }
    }

    static void answered(Context c, String id) {
        cancelRinging(c, id);
        Call call = calls.get(id);
        if (call != null) call.setActive();
        Zui.callEvent(ANSWER, id);
    }

    /** The app was opened by "Answer" on the notification. */
    static void fromIntent(Context c, Intent intent) {
        String id = intent == null ? null : intent.getStringExtra(EXTRA_ANSWER);
        if (id == null) return;
        intent.removeExtra(EXTRA_ANSWER);
        answered(c, id);
    }

    @Override
    public Connection onCreateIncomingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        return create(request, true);
    }

    @Override
    public Connection onCreateOutgoingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        Call call = create(request, false);
        call.setDialing();
        return call;
    }

    @Override
    public void onCreateIncomingConnectionFailed(PhoneAccountHandle account, ConnectionRequest request) {
        Bundle b = callExtras(request);
        showRinging(this, b.getString(EXTRA_ID, ""), b.getString(EXTRA_NAME, ""), b.getBoolean(EXTRA_VIDEO));
    }

    static Bundle callExtras(ConnectionRequest request) {
        Bundle b = request.getExtras();
        if (b == null) return new Bundle();
        Bundle inner = b.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS);
        if (inner == null) inner = b.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS);
        return inner != null ? inner : b;
    }

    Call create(ConnectionRequest request, boolean incoming) {
        Bundle b = callExtras(request);
        Call call = new Call(this, b.getString(EXTRA_ID, ""), b.getString(EXTRA_NAME, ""), b.getBoolean(EXTRA_VIDEO), incoming);
        calls.put(call.id, call);
        return call;
    }

    // ---- The ringing notification ----

    static int notificationId(String id) {
        return 0x5a000000 | (id.hashCode() & 0xffffff);
    }

    static void showRinging(Context c, String id, String name, boolean video) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Calls", NotificationManager.IMPORTANCE_HIGH);
            ch.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
            ch.enableVibration(true);
            ch.setVibrationPattern(new long[] {0, 1000, 1000});
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
        }
        int nid = notificationId(id);
        Intent launch = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
        if (launch == null) return;
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        // Full screen while ringing (shows the app over the lock screen); "Answer" opens it too.
        Intent show = new Intent(launch).putExtra("zui_alert", true);
        Intent answer = new Intent(launch).putExtra("zui_alert", true).putExtra(EXTRA_ANSWER, id);
        Intent decline = new Intent(c, ZuiCallReceiver.class).putExtra(EXTRA_ID, id);
        int flags = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        PendingIntent showPi = PendingIntent.getActivity(c, nid, show, flags);
        PendingIntent answerPi = PendingIntent.getActivity(c, nid + 1, answer, flags);
        PendingIntent declinePi = PendingIntent.getBroadcast(c, nid + 2, decline, flags);

        Notification.Builder b = new Notification.Builder(c, CHANNEL)
                .setSmallIcon(c.getApplicationInfo().icon != 0 ? c.getApplicationInfo().icon : android.R.drawable.sym_call_incoming)
                .setContentTitle(name)
                .setContentText(video ? "Video call" : "Voice call")
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setContentIntent(showPi)
                .setFullScreenIntent(showPi, true);
        if (Build.VERSION.SDK_INT >= 31) {
            android.app.Person caller = new android.app.Person.Builder().setName(name).setImportant(true).build();
            b.setStyle(Notification.CallStyle.forIncomingCall(caller, declinePi, answerPi).setIsVideo(video));
        } else {
            b.addAction(new Notification.Action.Builder(null, "Decline", declinePi).build());
            b.addAction(new Notification.Action.Builder(null, "Answer", answerPi).build());
        }
        Notification n = b.build();
        n.flags |= Notification.FLAG_INSISTENT;
        nm.notify(nid, n);
    }

    static void cancelRinging(Context c, String id) {
        c.getSystemService(NotificationManager.class).cancel(notificationId(id));
    }
}
