package com.wufour.zui;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.widget.RemoteViews;

/**
 * The app's home-screen widget: a title and up to three lines the app last wrote with
 * zui.widget.update (kept in SharedPreferences, so it shows even when the app is not running).
 * Tapping it opens the app. The app's manifest declares it:
 *   <receiver android:name="com.wufour.zui.ZuiWidget" android:exported="false">
 *     <intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE" /></intent-filter>
 *     <meta-data android:name="android.appwidget.provider" android:resource="@xml/zui_widget_info" />
 *   </receiver>
 */
public final class ZuiWidget extends AppWidgetProvider {
    static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("zui_widget", Context.MODE_PRIVATE);
    }

    @Override
    public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
        render(context, manager, ids);
    }

    static void render(Context c, AppWidgetManager manager, int[] ids) {
        String pkg = c.getPackageName();
        int layout = c.getResources().getIdentifier("zui_widget", "layout", pkg);
        if (layout == 0) return;
        SharedPreferences p = prefs(c);
        RemoteViews v = new RemoteViews(pkg, layout);
        String[] fields = {"title", "line1", "line2", "line3"};
        for (String f : fields) {
            int id = c.getResources().getIdentifier("zui_widget_" + f, "id", pkg);
            if (id != 0) v.setTextViewText(id, p.getString(f, ""));
        }
        Intent open = c.getPackageManager().getLaunchIntentForPackage(pkg);
        int root = c.getResources().getIdentifier("zui_widget_root", "id", pkg);
        if (open != null && root != 0) v.setOnClickPendingIntent(root, PendingIntent.getActivity(c, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        for (int id : ids) manager.updateAppWidget(id, v);
    }

    /** From the app: new content, shown at once on every placed widget. */
    static void update(Context c, String title, String line1, String line2, String line3) {
        prefs(c).edit().putString("title", title).putString("line1", line1).putString("line2", line2).putString("line3", line3).apply();
        AppWidgetManager m = AppWidgetManager.getInstance(c);
        render(c, m, m.getAppWidgetIds(new ComponentName(c, ZuiWidget.class)));
    }
}
