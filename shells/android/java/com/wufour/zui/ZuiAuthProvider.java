package com.wufour.zui;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;

/**
 * Single sign-on between our apps on one phone (zui.wufour), as Google's apps share an account:
 * each app serves its Wufour token at content://&lt;package&gt;.wufourauth/token, readable only by
 * apps signed with the same key (the signature permission com.wufour.permission.SHARED_AUTH,
 * which every app declares and uses; tools/apk.zig adds all of it to the manifest).
 *
 * query: the token this app keeps (one row, column "token"), or no row.
 * delete: forget it (a sign-out in another app); this app is signed out on its next resume
 *         or 401.
 */
public final class ZuiAuthProvider extends ContentProvider {
    static final String KEY = "token";

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        MatrixCursor c = new MatrixCursor(new String[] { "token" });
        Context cx = getContext();
        if (cx == null) return c;
        String t = Zui.storageGet(cx, KEY, true);
        if (t != null && !t.isEmpty()) c.addRow(new Object[] { t });
        return c;
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        Context cx = getContext();
        if (cx == null) return 0;
        boolean had = Zui.storageGet(cx, KEY, true) != null;
        Zui.storageRemoveNow(cx, KEY, true);
        return had ? 1 : 0;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        return 0;
    }

    static Uri uri(String pkg) {
        return Uri.parse("content://" + pkg + ".wufourauth/token");
    }

    /** From Zig: the first token another of our apps keeps (`apps`: packages, comma-separated). */
    static String findShared(String apps) {
        Context cx = Zui.ctx();
        if (cx == null) return null;
        String self = cx.getPackageName();
        for (String pkg : apps.split(",")) {
            pkg = pkg.trim();
            if (pkg.isEmpty() || pkg.equals(self)) continue;
            try (Cursor c = cx.getContentResolver().query(uri(pkg), null, null, null, null)) {
                if (c != null && c.moveToFirst()) {
                    String t = c.getString(0);
                    if (t != null && !t.isEmpty()) return t;
                }
            } catch (Exception ignored) {
                // not installed, an older build without the provider, or another signing key
            }
        }
        return null;
    }

    /** From Zig: sign every other app of ours out. */
    static void clearShared(String apps) {
        Context cx = Zui.ctx();
        if (cx == null) return;
        String self = cx.getPackageName();
        for (String pkg : apps.split(",")) {
            pkg = pkg.trim();
            if (pkg.isEmpty() || pkg.equals(self)) continue;
            try {
                cx.getContentResolver().delete(uri(pkg), null, null);
            } catch (Exception ignored) {
            }
        }
    }
}
