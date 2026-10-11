package com.wufour.zui;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * Keeps the app running with the screen off while it follows the position (a courier's shift):
 * a foreground service of type location with its notification. The positions themselves still
 * come from Zui's LocationManager listener; this service only keeps the process alive.
 * The app's manifest declares it:
 *   <service android:name="com.wufour.zui.ZuiLocationService" android:foregroundServiceType="location" android:exported="false" />
 */
public final class ZuiLocationService extends Service {
    static final String CHANNEL = "zui-location";

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = intent != null ? intent.getStringExtra("title") : null;
        String text = intent != null ? intent.getStringExtra("text") : null;
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, title != null ? title : "Location", NotificationManager.IMPORTANCE_LOW));
        }
        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent tap = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle(title != null ? title : "")
                .setContentText(text != null ? text : "")
                .setSmallIcon(getApplicationInfo().icon != 0 ? getApplicationInfo().icon : android.R.drawable.ic_menu_mylocation)
                .setOngoing(true)
                .setContentIntent(tap)
                .build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        else startForeground(1, n);
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
