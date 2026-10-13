package com.wufour.zui;

import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Context;
import android.graphics.Typeface;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import java.util.Calendar;
import java.util.Locale;
import android.content.Intent;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Build;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.WindowManager;

/**
 * The device around the views: Back, the screen kept on, vibration and sound, the network and
 * the app going to the background. Called from zui's Zig code (host/android.zig) and from
 * ZuiActivity.
 */
final class ZuiDevice {
    static final int ONLINE = 1, OFFLINE = 2, VISIBLE = 3, HIDDEN = 4;

    // Implemented in Zig (libapp.so).
    /** Back: whether the app took it (its own handler, or a link to go back to). */
    static native boolean nativeBack();
    /** The app was opened again with a new address (a deep link). */
    static native void nativeLink(String link);
    static native void nativeDevice(int kind);
    /** A picker's answer: "YYYY-MM-DD", "HH:MM", or the index of the option chosen. */
    static native void nativePickDone(String value);

    // ---- Back ----

    /** The app handles Back now (zui told us); otherwise the activity's default (leave). */
    static boolean backWanted;

    static void backState(boolean handler, boolean history, boolean rtl) {
        boolean want = handler || history;
        if (want == backWanted) return;
        backWanted = want;
        if (Build.VERSION.SDK_INT >= 33) Back33.set(want);
    }

    /** From onBackPressed (Android 12 and older, or without the predictive back opt-in) and the
     *  Android 13+ callback. False: the activity does its default. */
    static boolean back() {
        return Zui.started && nativeBack();
    }

    /** Android 13+: the callback is registered only while the app handles Back, so the system
     *  can show its "back to home" animation when it does not. */
    static final class Back33 {
        static android.window.OnBackInvokedCallback callback;

        static void set(boolean on) {
            android.window.OnBackInvokedDispatcher d = Zui.activity.getOnBackInvokedDispatcher();
            if (callback == null) callback = () -> back();
            if (on) d.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
            else d.unregisterOnBackInvokedCallback(callback);
        }
    }

    static void link(String link) {
        if (Zui.started && link != null) nativeLink(link);
    }

    // ---- Visible / hidden, online / offline ----

    static void visible(boolean on) {
        if (Zui.started) nativeDevice(on ? VISIBLE : HIDDEN);
    }

    static boolean watchingNetwork;

    /** After start: the current state, then every change (needs ACCESS_NETWORK_STATE in the
     *  manifest; without it the app is taken to be online). */
    static void watchNetwork() {
        if (watchingNetwork) return;
        watchingNetwork = true;
        try {
            ConnectivityManager cm = (ConnectivityManager) Zui.activity.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm.getActiveNetwork() == null) nativeDevice(OFFLINE);
            cm.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network n) {
                    Zui.main.post(() -> nativeDevice(ONLINE));
                }

                @Override
                public void onLost(Network n) {
                    Zui.main.post(() -> nativeDevice(OFFLINE));
                }
            });
        } catch (Exception ignored) {
            // no ACCESS_NETWORK_STATE
        }
    }

    // ---- Screen, vibration, sound ----

    static void keepAwake(boolean on) {
        if (on) Zui.activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else Zui.activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /** Needs VIBRATE in the manifest; without it nothing happens. */
    static void vibrate(int ms) {
        try {
            Vibrator v = (Vibrator) Zui.activity.getSystemService(Context.VIBRATOR_SERVICE);
            if (v != null && v.hasVibrator()) v.vibrate(VibrationEffect.createOneShot(Math.max(1, ms), VibrationEffect.DEFAULT_AMPLITUDE));
        } catch (Exception ignored) {
        }
    }

    static ToneGenerator tones;

    static void beep() {
        try {
            if (tones == null) tones = new ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80);
            tones.startTone(ToneGenerator.TONE_PROP_BEEP, 150);
        } catch (Exception ignored) {
            // no audio focus / tone generator
        }
    }

    // ---- Inputs: keyboard, enter key, password ----

    static void inputType(int id, int keyboard, int returnKey, boolean secure) {
        View v = Zui.views.get(id);
        if (!(v instanceof EditText)) return;
        EditText e = (EditText) v;
        boolean area = (e.getInputType() & InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0;
        int t;
        switch (keyboard) {
            case 1: t = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS; break;
            case 2: t = InputType.TYPE_CLASS_NUMBER; break;
            case 3: t = InputType.TYPE_CLASS_PHONE; break;
            case 4: t = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI; break;
            case 5: t = InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL; break;
            default: t = InputType.TYPE_CLASS_TEXT | (area ? InputType.TYPE_TEXT_FLAG_CAP_SENTENCES : 0);
        }
        if (secure) t = keyboard == 2 ? InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD : InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD;
        if (area) t |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        // A password type switches the font to monospace: keep zui's.
        Typeface face = e.getTypeface();
        int at = e.getSelectionEnd();
        e.setInputType(t);
        e.setTypeface(face);
        if (at >= 0) e.setSelection(Math.min(at, e.length()));
        int[] actions = {area ? EditorInfo.IME_ACTION_NONE : EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_GO,
                EditorInfo.IME_ACTION_NEXT, EditorInfo.IME_ACTION_SEARCH, EditorInfo.IME_ACTION_SEND};
        e.setImeOptions(actions[Math.max(0, Math.min(returnKey, actions.length - 1))]);
    }

    // ---- Pickers: the platform's date and time dialogs and a list dialog ----

    static final int PICK_DATE = 1, PICK_TIME = 2, PICK_OPTION = 3;

    static void picked(String value) {
        if (Zui.started) nativePickDone(value);
    }

    /** "YYYY-MM-DD" (or "HH:MM") as numbers, or null. */
    static int[] numbers(String s, String sep, int count) {
        String[] parts = s.split(sep);
        if (parts.length != count) return null;
        int[] out = new int[count];
        try {
            for (int i = 0; i < count; i++) out[i] = Integer.parseInt(parts[i].trim());
        } catch (NumberFormatException e) {
            return null;
        }
        return out;
    }

    static long dayMillis(String day) {
        int[] d = numbers(day, "-", 3);
        if (d == null) return -1;
        Calendar c = Calendar.getInstance();
        c.clear();
        c.set(d[0], d[1] - 1, d[2]);
        return c.getTimeInMillis();
    }

    static void pick(int kind, String value, String min, String max, String title, String options, int selected) {
        android.app.Activity a = Zui.activity;
        int theme = Zui.dark ? android.R.style.Theme_DeviceDefault_Dialog_Alert : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert;
        if (kind == PICK_DATE) {
            Calendar now = Calendar.getInstance();
            int[] d = numbers(value, "-", 3);
            if (d == null) d = new int[] {now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH)};
            DatePickerDialog dialog = new DatePickerDialog(a, theme,
                    (view, y, m, day) -> picked(String.format(Locale.ROOT, "%04d-%02d-%02d", y, m + 1, day)), d[0], d[1] - 1, d[2]);
            long lo = dayMillis(min), hi = dayMillis(max);
            if (lo >= 0) dialog.getDatePicker().setMinDate(lo);
            if (hi >= 0) dialog.getDatePicker().setMaxDate(hi);
            dialog.show();
        } else if (kind == PICK_TIME) {
            Calendar now = Calendar.getInstance();
            int[] t = numbers(value, ":", 2);
            if (t == null) t = new int[] {now.get(Calendar.HOUR_OF_DAY), now.get(Calendar.MINUTE)};
            new TimePickerDialog(a, theme, (view, h, m) -> picked(String.format(Locale.ROOT, "%02d:%02d", h, m)), t[0], t[1],
                    android.text.format.DateFormat.is24HourFormat(a)).show();
        } else {
            String[] items = options.isEmpty() ? new String[0] : options.split("\n", -1);
            AlertDialog.Builder b = new AlertDialog.Builder(a, theme);
            if (!title.isEmpty()) b.setTitle(title);
            b.setSingleChoiceItems(items, selected, (dialog, which) -> {
                dialog.dismiss();
                picked(String.valueOf(which));
            });
            b.show();
        }
    }

    // ---- Photos and files: the camera, the photo picker, the document picker, Downloads ----

    static final int REQUEST_CAMERA = 7101, REQUEST_PERMISSION = 7102, REQUEST_PHOTO = 7103, REQUEST_FILE = 7104;
    /** A file the user chose: bytes, name, MIME type, and a photo's size after scaling. */
    static native void nativeFileDone(byte[] data, String name, String mime, int width, int height);

    static int photoMax = 1600, photoQuality = 85;
    /** Where the camera writes the photo (MediaStore, removed once read). */
    static android.net.Uri cameraUri;
    static final java.util.concurrent.ExecutorService files = java.util.concurrent.Executors.newSingleThreadExecutor();

    static void fileDone(byte[] data, String name, String mime, int w, int h) {
        Zui.main.post(() -> {
            if (Zui.started) nativeFileDone(data, name, mime, w, h);
        });
    }

    /** Whether the manifest asks for a permission: an app that declares CAMERA must hold it to
     *  start the camera app, one that does not can start it without. */
    static boolean declares(String permission) {
        try {
            String[] all = Zui.activity.getPackageManager().getPackageInfo(Zui.activity.getPackageName(), android.content.pm.PackageManager.GET_PERMISSIONS).requestedPermissions;
            if (all != null) for (String p : all) if (p.equals(permission)) return true;
        } catch (Exception ignored) {
        }
        return false;
    }

    static void pickPhoto(boolean camera, int max, int quality) {
        photoMax = max;
        photoQuality = quality;
        android.app.Activity a = Zui.activity;
        if (!camera) {
            Intent i = Build.VERSION.SDK_INT >= 33 ? new Intent(android.provider.MediaStore.ACTION_PICK_IMAGES).setType("image/*")
                    : new Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE);
            start(i, REQUEST_PHOTO);
            return;
        }
        if (declares(android.Manifest.permission.CAMERA) && a.checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            a.requestPermissions(new String[] {android.Manifest.permission.CAMERA}, REQUEST_PERMISSION);
            return;
        }
        openCamera();
    }

    static void openCamera() {
        Intent i = new Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE);
        cameraUri = null;
        if (Build.VERSION.SDK_INT >= 29) {
            android.content.ContentValues v = new android.content.ContentValues();
            v.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, "zui-" + System.currentTimeMillis() + ".jpg");
            v.put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "image/jpeg");
            try {
                cameraUri = Zui.activity.getContentResolver().insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v);
            } catch (Exception ignored) {
            }
            if (cameraUri != null) {
                i.putExtra(android.provider.MediaStore.EXTRA_OUTPUT, cameraUri);
                i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
        }
        start(i, REQUEST_CAMERA);
    }

    static void start(Intent i, int code) {
        try {
            Zui.activity.startActivityForResult(i, code);
        } catch (Exception e) {
            // no app for it
        }
    }

    static void pickFile(String accept) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE);
        java.util.ArrayList<String> types = new java.util.ArrayList<>();
        boolean extensions = false;
        for (String t : accept.split(",")) {
            t = t.trim();
            if (t.isEmpty()) continue;
            if (t.contains("/")) types.add(t);
            // Android files CSV as text/comma-separated-values.
            if (t.equals("text/csv")) types.add("text/comma-separated-values");
            else extensions = true;
        }
        // Extensions (".csv") cannot be asked for here: then anything.
        if (extensions) types.clear();
        if (types.size() == 1) i.setType(types.get(0));
        else {
            i.setType("*/*");
            if (types.size() > 1) i.putExtra(Intent.EXTRA_MIME_TYPES, types.toArray(new String[0]));
        }
        start(i, REQUEST_FILE);
    }

    /** From the activity. */
    static boolean permissionResult(int code, int[] results) {
        if (code != REQUEST_PERMISSION) return false;
        if (results.length > 0 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) openCamera();
        return true;
    }

    /** From the activity: whether the result was one of ours. */
    static boolean activityResult(int code, int result, Intent data) {
        if (code != REQUEST_CAMERA && code != REQUEST_PHOTO && code != REQUEST_FILE) return false;
        android.content.ContentResolver cr = Zui.activity.getContentResolver();
        final android.net.Uri camera = cameraUri;
        cameraUri = null;
        if (result != android.app.Activity.RESULT_OK) {
            if (camera != null) files.execute(() -> delete(cr, camera));
            return true;
        }
        final int max = photoMax, quality = photoQuality;
        if (code == REQUEST_CAMERA) {
            if (camera != null) {
                files.execute(() -> {
                    photo(cr, camera, "photo.jpg", max, quality);
                    delete(cr, camera);
                });
            } else if (data != null && data.getExtras() != null && data.getExtras().get("data") instanceof android.graphics.Bitmap) {
                // Android 9 and older without a place to write: the camera's small preview.
                android.graphics.Bitmap b = (android.graphics.Bitmap) data.getExtras().get("data");
                files.execute(() -> jpeg(b, 0, max, quality, "photo.jpg"));
            }
            return true;
        }
        final android.net.Uri uri = data != null ? data.getData() : null;
        if (uri == null) return true;
        if (code == REQUEST_PHOTO) files.execute(() -> photo(cr, uri, baseName(displayName(cr, uri, "photo")) + ".jpg", max, quality));
        else files.execute(() -> {
            byte[] bytes = read(cr, uri);
            String mime = cr.getType(uri);
            if (bytes != null) fileDone(bytes, displayName(cr, uri, "file"), mime != null ? mime : "application/octet-stream", 0, 0);
        });
        return true;
    }

    static void delete(android.content.ContentResolver cr, android.net.Uri uri) {
        try {
            cr.delete(uri, null, null);
        } catch (Exception ignored) {
        }
    }

    static String displayName(android.content.ContentResolver cr, android.net.Uri uri, String fallback) {
        try (android.database.Cursor c = cr.query(uri, new String[] {android.provider.OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst() && c.getString(0) != null) return c.getString(0);
        } catch (Exception ignored) {
        }
        return fallback;
    }

    static String baseName(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    static byte[] read(android.content.ContentResolver cr, android.net.Uri uri) {
        try (java.io.InputStream in = cr.openInputStream(uri)) {
            if (in == null) return null;
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] chunk = new byte[65536];
            for (int n; (n = in.read(chunk)) > 0; ) out.write(chunk, 0, n);
            return out.toByteArray();
        } catch (Exception e) {
            return null;
        }
    }

    /** On the files thread: decode at about the size wanted, turn upright (EXIF), scale, JPEG. */
    static void photo(android.content.ContentResolver cr, android.net.Uri uri, String name, int max, int quality) {
        byte[] bytes = read(cr, uri);
        if (bytes == null) return;
        android.graphics.BitmapFactory.Options o = new android.graphics.BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.length, o);
        if (o.outWidth <= 0 || o.outHeight <= 0) return;
        int sample = 1;
        while (Math.max(o.outWidth, o.outHeight) / (sample * 2) >= max) sample *= 2;
        o = new android.graphics.BitmapFactory.Options();
        o.inSampleSize = sample;
        android.graphics.Bitmap b = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.length, o);
        if (b == null) return;
        int rotate = 0;
        try {
            android.media.ExifInterface exif = new android.media.ExifInterface(new java.io.ByteArrayInputStream(bytes));
            switch (exif.getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)) {
                case 6: rotate = 90; break;
                case 3: rotate = 180; break;
                case 8: rotate = 270; break;
            }
        } catch (Exception ignored) {
        }
        jpeg(b, rotate, max, quality, name);
    }

    static void jpeg(android.graphics.Bitmap b, int rotate, int max, int quality, String name) {
        float k = Math.min(1f, (float) max / Math.max(b.getWidth(), b.getHeight()));
        android.graphics.Matrix m = new android.graphics.Matrix();
        m.postScale(k, k);
        m.postRotate(rotate);
        android.graphics.Bitmap out = android.graphics.Bitmap.createBitmap(b, 0, 0, b.getWidth(), b.getHeight(), m, true);
        java.io.ByteArrayOutputStream jpeg = new java.io.ByteArrayOutputStream();
        out.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, jpeg);
        fileDone(jpeg.toByteArray(), name, "image/jpeg", out.getWidth(), out.getHeight());
    }

    /** Into Downloads (Android 10+: MediaStore, no permission; older: the app's own Downloads
     *  folder), then the share sheet when asked. */
    static void saveFile(String name, String mime, byte[] data, boolean share) {
        android.app.Activity a = Zui.activity;
        files.execute(() -> {
            android.net.Uri uri = null;
            try {
                if (Build.VERSION.SDK_INT >= 29) {
                    android.content.ContentValues v = new android.content.ContentValues();
                    v.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name);
                    v.put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime);
                    uri = a.getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                    if (uri == null) return;
                    try (java.io.OutputStream out = a.getContentResolver().openOutputStream(uri)) {
                        out.write(data);
                    }
                } else {
                    java.io.File dir = a.getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS);
                    if (dir == null) return;
                    try (java.io.FileOutputStream out = new java.io.FileOutputStream(new java.io.File(dir, name))) {
                        out.write(data);
                    }
                }
            } catch (Exception e) {
                return;
            }
            final android.net.Uri saved = uri;
            Zui.main.post(() -> {
                if (share && saved != null) {
                    Intent send = new Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, saved).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    start(Intent.createChooser(send, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), 7105);
                } else {
                    android.widget.Toast.makeText(a, name, android.widget.Toast.LENGTH_SHORT).show();
                }
            });
        });
    }

    // ---- Event streams: a GET whose answer is read as it arrives, a thread each ----

    static native void nativeStreamStatus(int id, int status);
    static native void nativeStreamData(int id, byte[] data);
    static native void nativeStreamEnd(int id);
    static final java.util.HashMap<Integer, java.net.HttpURLConnection[]> streams = new java.util.HashMap<>();

    static void streamOpen(int id, String url, String headers) {
        final java.net.HttpURLConnection[] holder = new java.net.HttpURLConnection[1];
        streams.put(id, holder);
        new Thread(() -> {
            try {
                java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
                synchronized (holder) {
                    holder[0] = c;
                }
                c.setConnectTimeout(15000);
                c.setReadTimeout(0); // events may be minutes apart
                c.setUseCaches(false);
                for (String line : headers.split("\n")) {
                    int at = line.indexOf(": ");
                    if (at > 0) c.setRequestProperty(line.substring(0, at), line.substring(at + 2));
                }
                int status = c.getResponseCode();
                Zui.main.post(() -> {
                    if (streams.get(id) == holder) nativeStreamStatus(id, status);
                });
                java.io.InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                if (in != null) {
                    try (java.io.InputStream s = in) {
                        byte[] chunk = new byte[8192];
                        for (int n; (n = s.read(chunk)) > 0; ) {
                            final byte[] part = java.util.Arrays.copyOf(chunk, n);
                            Zui.main.post(() -> {
                                if (streams.get(id) == holder) nativeStreamData(id, part);
                            });
                        }
                    }
                }
            } catch (Exception ignored) {
                // lost or closed: zui connects again
            }
            Zui.main.post(() -> {
                if (streams.get(id) != holder) return;
                streams.remove(id);
                nativeStreamEnd(id);
            });
        }, "zui-events").start();
    }

    static void streamClose(int id) {
        java.net.HttpURLConnection[] holder = streams.remove(id);
        if (holder == null) return;
        new Thread(() -> {
            synchronized (holder) {
                if (holder[0] != null) holder[0].disconnect();
            }
        }).start();
    }

    // ---- Secure keys in the AndroidKeyStore (zui/keys.zig's hardware hook) ----
    // EC P-256 keys for signing (and, from Android 12, key agreement) live in the Keystore,
    // in the phone's secure hardware where it has one. An imported key needs a certificate: a
    // self-signed one is made here (the Keystore only stores it).

    static final int KIND_ECDH = 1, KIND_ECDSA = 2;

    static boolean keysSupported(int kind) {
        return kind == KIND_ECDSA || (kind == KIND_ECDH && Build.VERSION.SDK_INT >= 31);
    }

    static int purposes(int kind) {
        return kind == KIND_ECDSA ? android.security.keystore.KeyProperties.PURPOSE_SIGN : 64 /* PURPOSE_AGREE_KEY, API 31 */;
    }

    static java.security.KeyStore keystore() throws Exception {
        java.security.KeyStore ks = java.security.KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        return ks;
    }

    /** The uncompressed point of a P-256 public key. */
    static byte[] rawPublic(java.security.PublicKey key) {
        java.security.spec.ECPoint w = ((java.security.interfaces.ECPublicKey) key).getW();
        byte[] out = new byte[65];
        out[0] = 4;
        fixed(w.getAffineX(), out, 1);
        fixed(w.getAffineY(), out, 33);
        return out;
    }

    static void fixed(java.math.BigInteger v, byte[] out, int at) {
        byte[] b = v.toByteArray();
        int n = Math.min(b.length, 32);
        System.arraycopy(b, b.length - n, out, at + 32 - n, n);
    }

    static final byte[] SPKI_HEAD = {0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, (byte) 0x86, 0x48, (byte) 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, (byte) 0x86, 0x48, (byte) 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00};

    static java.security.PublicKey publicFromRaw(byte[] raw) throws Exception {
        byte[] spki = new byte[SPKI_HEAD.length + raw.length];
        System.arraycopy(SPKI_HEAD, 0, spki, 0, SPKI_HEAD.length);
        System.arraycopy(raw, 0, spki, SPKI_HEAD.length, raw.length);
        return java.security.KeyFactory.getInstance("EC").generatePublic(new java.security.spec.X509EncodedKeySpec(spki));
    }

    /** DER: a tag and its contents. */
    static byte[] der(int tag, byte[]... parts) {
        java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream();
        for (byte[] p : parts) body.write(p, 0, p.length);
        int n = body.size();
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        out.write(tag);
        if (n < 128) out.write(n);
        else if (n < 256) { out.write(0x81); out.write(n); }
        else { out.write(0x82); out.write(n >> 8); out.write(n & 0xff); }
        byte[] b = body.toByteArray();
        out.write(b, 0, b.length);
        return out.toByteArray();
    }

    static byte[] bytes(int... v) {
        byte[] out = new byte[v.length];
        for (int i = 0; i < v.length; i++) out[i] = (byte) v[i];
        return out;
    }

    /** A self-signed certificate for an imported key (CN=zui, 2025 to 2049). */
    static java.security.cert.Certificate selfSigned(java.security.PrivateKey priv, byte[] rawPublic) throws Exception {
        byte[] alg = der(0x30, bytes(0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02));
        byte[] name = der(0x30, der(0x31, der(0x30, bytes(0x06, 0x03, 0x55, 0x04, 0x03), der(0x0c, "zui".getBytes("UTF-8")))));
        byte[] validity = der(0x30, der(0x17, "250101000000Z".getBytes("US-ASCII")), der(0x17, "491231235959Z".getBytes("US-ASCII")));
        byte[] spki = new byte[SPKI_HEAD.length + 65];
        System.arraycopy(SPKI_HEAD, 0, spki, 0, SPKI_HEAD.length);
        System.arraycopy(rawPublic, 0, spki, SPKI_HEAD.length, 65);
        byte[] tbs = der(0x30, der(0xa0, bytes(0x02, 0x01, 0x02)), bytes(0x02, 0x01, 0x01), alg, name, validity, name, spki);
        java.security.Signature s = java.security.Signature.getInstance("SHA256withECDSA");
        s.initSign(priv);
        s.update(tbs);
        byte[] sig = s.sign();
        byte[] bits = new byte[sig.length + 1];
        System.arraycopy(sig, 0, bits, 1, sig.length);
        byte[] cert = der(0x30, tbs, alg, der(0x03, bits));
        return java.security.cert.CertificateFactory.getInstance("X.509").generateCertificate(new java.io.ByteArrayInputStream(cert));
    }

    /** Imports a PKCS#8 P-256 key as `alias`, usable only inside the Keystore; its public key, or null. */
    static byte[] keyImport(String alias, int kind, byte[] pkcs8, byte[] rawPublic) {
        if (!keysSupported(kind)) return null;
        try {
            java.security.PrivateKey priv = java.security.KeyFactory.getInstance("EC").generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(pkcs8));
            java.security.cert.Certificate cert = selfSigned(priv, rawPublic);
            android.security.keystore.KeyProtection.Builder p = new android.security.keystore.KeyProtection.Builder(purposes(kind));
            if (kind == KIND_ECDSA) p.setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256);
            keystore().setEntry(alias, new java.security.KeyStore.PrivateKeyEntry(priv, new java.security.cert.Certificate[] {cert}), p.build());
            return rawPublic;
        } catch (Exception e) {
            android.util.Log.e("zui", "keystore import: " + e);
            return null;
        }
    }

    /** A new key made inside the Keystore; its public key, or null. */
    static byte[] keyGenerate(String alias, int kind) {
        if (!keysSupported(kind)) return null;
        try {
            java.security.KeyPairGenerator g = java.security.KeyPairGenerator.getInstance("EC", "AndroidKeyStore");
            android.security.keystore.KeyGenParameterSpec.Builder b = new android.security.keystore.KeyGenParameterSpec.Builder(alias, purposes(kind))
                    .setAlgorithmParameterSpec(new java.security.spec.ECGenParameterSpec("secp256r1"));
            if (kind == KIND_ECDSA) b.setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256);
            g.initialize(b.build());
            return rawPublic(g.generateKeyPair().getPublic());
        } catch (Exception e) {
            android.util.Log.e("zui", "keystore generate: " + e);
            return null;
        }
    }

    /** ECDSA P-256 SHA-256, as r||s (64 bytes), or null. */
    static byte[] keySign(String alias, byte[] data) {
        try {
            java.security.Signature s = java.security.Signature.getInstance("SHA256withECDSA");
            s.initSign((java.security.PrivateKey) keystore().getKey(alias, null));
            s.update(data);
            byte[] d = s.sign();
            // DER SEQUENCE { INTEGER r, INTEGER s } -> r||s
            int i = 2 + (d[1] == (byte) 0x81 ? 1 : 0);
            byte[] out = new byte[64];
            for (int k = 0; k < 2; k++) {
                int len = d[i + 1];
                byte[] v = java.util.Arrays.copyOfRange(d, i + 2, i + 2 + len);
                fixed(new java.math.BigInteger(1, v), out, k * 32);
                i += 2 + len;
            }
            return out;
        } catch (Exception e) {
            android.util.Log.e("zui", "keystore sign: " + e);
            return null;
        }
    }

    /** The ECDH shared secret (32 bytes) with a raw public key, or null. */
    static byte[] keyEcdh(String alias, byte[] peer) {
        try {
            javax.crypto.KeyAgreement ka = javax.crypto.KeyAgreement.getInstance("ECDH", "AndroidKeyStore");
            ka.init((java.security.PrivateKey) keystore().getKey(alias, null));
            ka.doPhase(publicFromRaw(peer), true);
            return ka.generateSecret();
        } catch (Exception e) {
            android.util.Log.e("zui", "keystore ecdh: " + e);
            return null;
        }
    }

    static void keyDelete(String alias) {
        try {
            keystore().deleteEntry(alias);
        } catch (Exception ignored) {
        }
    }
}
