package com.wufour.zui;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.LruCache;
import android.view.Choreographer;
import android.view.ViewOutlineProvider;
import android.widget.ImageView;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import android.content.res.AssetManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.fonts.Font;
import android.graphics.fonts.FontFamily;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.SparseArray;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsetsController;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * The view primitives zui's Zig code calls through JNI, and the events it gets back. Generic and
 * fixed: which views exist, where they are and what they show is decided in Zig. Sizes from Zig
 * are logical points (dp); they become pixels here.
 */
public final class Zui {
    static final int VIEW = 0, TEXT = 1, INPUT = 2, SCROLL = 3, SCROLL_X = 4, IMAGE = 5, PATH = 6, VIDEO = 7, TEXT_AREA = 8;
    static final int POINTER_DOWN = 1, POINTER_MOVE = 2, POINTER_UP = 3, POINTER_CANCEL = 4;

    /** Images: decoded bitmaps in memory (1/8 of the heap), downloads on four threads. The HTTP
     *  cache installed by the activity keeps them on disk across launches.
     *
     *  Downloads run newest first, and one that no view wants any more by the time a thread is
     *  free is dropped: zooming quickly through a map asks for many tiles that are gone a moment
     *  later, and they must not delay the ones on screen. */
    static final LruCache<String, Bitmap> bitmaps = new LruCache<String, Bitmap>((int) Math.min(Integer.MAX_VALUE, Runtime.getRuntime().maxMemory() / 8)) {
        @Override
        protected int sizeOf(String key, Bitmap b) {
            return b.getByteCount();
        }
    };
    static final ThreadPoolExecutor loader = new ThreadPoolExecutor(4, 4, 30, TimeUnit.SECONDS, new LinkedBlockingDeque<Runnable>() {
        @Override
        public boolean offer(Runnable r) {
            return offerFirst(r);
        }
    });
    /** How many image views want each URL (changed on the UI thread, read by the loader). */
    static final ConcurrentHashMap<String, Integer> wanted = new ConcurrentHashMap<>();
    /** Image views waiting for a download, by URL (UI thread only). */
    static final HashMap<String, ArrayList<ImageView>> waiting = new HashMap<>();
    static boolean frameRequested;
    static final int PRESS_IN = 1, PRESS_OUT = 2, PRESS = 3;

    static Activity activity;
    /** The application, when the app runs without its activity (a push woke it: ZuiPushHost). */
    static Context app;

    /** The activity, or the application while there is none. */
    static Context ctx() {
        return activity != null ? activity : app;
    }
    static ZuiLayout root;
    static float density = 1;
    static boolean started, dark;
    static float insetTop, insetRight, insetBottom, insetLeft;
    static final SparseArray<View> views = new SparseArray<>();
    static final SparseArray<Typeface> typefaces = new SparseArray<>();
    static final TextPaint paint = new TextPaint(TextPaint.ANTI_ALIAS_FLAG);

    // Implemented in Zig (libapp.so).
    static native void nativeStart(float width, float height, boolean dark, float top, float right, float bottom, float left, String lang, String link);
    static native void nativeResize(float width, float height);
    static native void nativeInsets(float top, float right, float bottom, float left);
    static native void nativeDark(boolean dark);
    static native void nativeEvent(int id, int kind);
    static native void nativeText(int id, String text);
    static native void nativeSelect(int id, int start, int end);
    static native void nativePointer(int id, int kind, int pointer, float x, float y, long timeMs);
    static native void nativeFrame(long timeNanos);
    static native void nativeFetchDone(int id, int status, byte[] body);
    static native void nativeTimer(int id);
    static native void nativeLocation(double lat, double lng, float accuracy, float heading, float speed);
    static native void nativeLocationError(boolean denied);
    static native void nativeInput(int id, int kind);
    /** kind: 1 open, 2 message (data), 3 closed. */
    static native void nativeSocket(int id, int kind, String data);
    /** kind: 1 answer, 2 decline, 3 end. */
    static native void nativeCall(int kind, String id);
    /** Delivers call events queued by other threads (zui/calls.zig). */
    static native void nativeCallsPump();
    /** Call events from before the app's Zig side started (answering opened the app). */
    static final java.util.ArrayList<Object[]> pendingCalls = new java.util.ArrayList<>();

    /** From the call screen (any thread, maybe before the app started). */
    static void callEvent(int kind, String id) {
        main.post(() -> {
            if (started) nativeCall(kind, id);
            else pendingCalls.add(new Object[] {kind, id});
        });
    }
    static final java.util.HashMap<Integer, ZuiSocket> sockets = new java.util.HashMap<>();

    static final int INPUT_FOCUS = 1, INPUT_BLUR = 2, INPUT_SUBMIT = 3;
    /** The address the app was opened with (an App Link), or null. */
    static String link;
    static final Handler main = new Handler(Looper.getMainLooper());
    /** Requests from the app (search, routes, ...), off the UI thread. */
    static final ExecutorService network = Executors.newFixedThreadPool(4);

    // ---- From the activity ----

    static void rootSized(int w, int h) {
        if (!started) {
            started = true;
            nativeStart(w / density, h / density, dark, insetTop, insetRight, insetBottom, insetLeft, java.util.Locale.getDefault().toLanguageTag(), link);
            for (Object[] e : pendingCalls) nativeCall((Integer) e[0], (String) e[1]);
            pendingCalls.clear();
            ZuiPushHost.flush();
            ZuiDevice.watchNetwork();
        } else {
            nativeResize(w / density, h / density);
        }
    }

    static void insets(int top, int right, int bottom, int left) {
        insetTop = top / density;
        insetRight = right / density;
        insetBottom = bottom / density;
        insetLeft = left / density;
        if (started) root.post(() -> nativeInsets(insetTop, insetRight, insetBottom, insetLeft));
    }

    static void darkChanged(boolean isDark) {
        dark = isDark;
        if (started) nativeDark(isDark);
    }

    // ---- Called from Zig ----

    static void create(int id, int kind) {
        View v;
        switch (kind) {
            case TEXT:
            case 9: // selectable text (ZuiStyle.richText)
            {
                TextView t = new TextView(activity);
                t.setIncludeFontPadding(false);
                t.setPadding(0, 0, 0, 0);
                t.setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);
                t.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
                v = t;
                break;
            }
            case INPUT:
            case TEXT_AREA: {
                EditText e = new EditText(activity) {
                    @Override
                    protected void onSelectionChanged(int start, int end) {
                        super.onSelectionChanged(start, end);
                        if (started && getTag() == null) {
                            String t = getText().toString();
                            nativeSelect(id, bytes(t, start), bytes(t, end));
                        }
                    }
                };
                e.setBackground(null);
                e.setPadding(0, 0, 0, 0);
                e.setIncludeFontPadding(false);
                if (kind == TEXT_AREA) {
                    // Wraps like a text view (zui measured it that way); scrolls past its frame.
                    e.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
                    e.setSingleLine(false);
                    e.setHorizontallyScrolling(false);
                    e.setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);
                    e.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
                    e.setImeOptions(EditorInfo.IME_ACTION_NONE);
                } else {
                    e.setSingleLine(true);
                    e.setInputType(InputType.TYPE_CLASS_TEXT);
                    e.setImeOptions(EditorInfo.IME_ACTION_DONE);
                }
                e.setOnFocusChangeListener((view, has) -> nativeInput(id, has ? INPUT_FOCUS : INPUT_BLUR));
                e.setOnEditorActionListener((view, action, ev) -> {
                    nativeInput(id, INPUT_SUBMIT);
                    return false;
                });
                e.addTextChangedListener(new TextWatcher() {
                    public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
                    public void onTextChanged(CharSequence s, int a, int b, int c) {}
                    public void afterTextChanged(Editable s) {
                        if (e.getTag() == null) nativeText(id, s.toString());
                    }
                });
                v = e;
                break;
            }
            case SCROLL: {
                ScrollView s = new ScrollView(activity);
                s.setFillViewport(false);
                s.setClipToPadding(true);
                s.addView(new ZuiLayout(activity), new ViewGroup.LayoutParams(0, 0));
                v = s;
                break;
            }
            case SCROLL_X: {
                HorizontalScrollView s = new HorizontalScrollView(activity);
                s.addView(new ZuiLayout(activity), new ViewGroup.LayoutParams(0, 0));
                v = s;
                break;
            }
            case IMAGE: {
                ImageView i = new ImageView(activity);
                i.setScaleType(ImageView.ScaleType.FIT_XY);
                v = i;
                break;
            }
            case PATH:
                v = new ZuiPath(activity);
                break;
            case VIDEO:
                v = ZuiMedia.createView(id);
                break;
            default:
                v = new ZuiLayout(activity);
        }
        v.setLayoutParams(new ZuiLayout.Params());
        views.put(id, v);
    }

    static void destroy(int id) {
        View v = views.get(id);
        if (v == null) return;
        if (v.getParent() instanceof ViewGroup) ((ViewGroup) v.getParent()).removeView(v);
        views.remove(id);
        if (v instanceof ImageView && v.getTag() instanceof String) unwant((String) v.getTag());
        if (v instanceof android.view.TextureView) ZuiMedia.destroyView(id);
    }

    /** The view children of `id` go into: scroll views hold a content box. */
    static ViewGroup container(int id) {
        if (id == 0) return root;
        View v = views.get(id);
        if (v instanceof ScrollView || v instanceof HorizontalScrollView) return (ViewGroup) ((ViewGroup) v).getChildAt(0);
        return (ViewGroup) v;
    }

    static void insert(int parent, int id, int index) {
        ViewGroup p = container(parent);
        View v = views.get(id);
        if (v.getParent() == p) {
            if (p.indexOfChild(v) == index) return;
            p.removeView(v);
        } else if (v.getParent() instanceof ViewGroup) {
            ((ViewGroup) v.getParent()).removeView(v);
        }
        p.addView(v, Math.min(index, p.getChildCount()));
    }

    static void frame(int id, float x, float y, float w, float h) {
        View v = views.get(id);
        ZuiLayout.Params p = (ZuiLayout.Params) v.getLayoutParams();
        // Edges are rounded, not sizes, so neighbours never gap or overlap.
        int l = Math.round(x * density), t = Math.round(y * density);
        p.x = l;
        p.y = t;
        p.width = Math.round((x + w) * density) - l;
        p.height = Math.round((y + h) * density) - t;
        v.setLayoutParams(p);
    }

    static void box(int id, int background, float radius, float borderWidth, int borderColor, float opacity) {
        View v = views.get(id);
        if (Color.alpha(background) == 0 && borderWidth <= 0) {
            v.setBackground(null);
        } else {
            GradientDrawable g = new GradientDrawable();
            g.setColor(background);
            g.setCornerRadius(radius * density);
            if (borderWidth > 0) g.setStroke(Math.max(1, Math.round(borderWidth * density)), borderColor);
            v.setBackground(g);
        }
        v.setAlpha(opacity);
    }

    static void pressable(int id, boolean on) {
        View v = views.get(id);
        if (!on) {
            v.setOnTouchListener(null);
            v.setClickable(false);
            return;
        }
        v.setClickable(true);
        v.setOnTouchListener((view, e) -> {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    nativeEvent(id, PRESS_IN);
                    return true;
                case MotionEvent.ACTION_UP:
                    nativeEvent(id, PRESS_OUT);
                    if (e.getX() >= 0 && e.getY() >= 0 && e.getX() <= view.getWidth() && e.getY() <= view.getHeight()) {
                        view.performClick();
                        nativeEvent(id, PRESS);
                    }
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    nativeEvent(id, PRESS_OUT);
                    return true;
            }
            return true;
        });
    }

    // ---- Fonts ----
    // Wufour's own faces, decided in Zig (zui/font.zig: which face carries which script and
    // weight) and loaded here from the APK's assets/fonts/. Java only turns (face, weight) into
    // a Typeface.

    /** zui.font.Face: 0 Wufour Sans, 1 Wufour Arabic, 2 the system monospace. */
    static final int FACE_SANS = 0, FACE_ARABIC = 1, FACE_MONO = 2;
    static final String FONT_DIR = "fonts/";
    static final String[] FONT_FAMILIES = { "WufourSansGolden", "WufourArabicGolden" };
    /** Our faces by (face, weight step), once loaded; null where the file could not be read. */
    static final Typeface[] wufourFaces = new Typeface[6];
    static final boolean[] wufourTried = new boolean[6];

    /** 400, 500 or 700 as 0, 1, 2: the same steps as zui/font.zig's `weight`. */
    static int weightStep(int weight) {
        return weight < 450 ? 0 : weight < 600 ? 1 : 2;
    }

    /** The asset of a Wufour face at a weight: fonts/WufourSansGolden-Medium.ttf and the like. */
    static String fontFile(int face, int weight) {
        String[] styles = { "Regular", "Medium", "Bold" };
        return FONT_DIR + FONT_FAMILIES[face] + "-" + styles[weightStep(weight)] + ".ttf";
    }

    /**
     * Wufour Sans or Wufour Arabic at a weight, or null when its file is not in the assets.
     * From API 29 the typeface is a chain: the face asked for, then the other Wufour face for the
     * glyphs it lacks (Latin words inside Arabic keep the Sans and the other way round), then the
     * system's fonts for everything else. Before 29 a typeface holds one file; zui picks the face
     * by the text's script and Android's own fallback fills in the rest.
     */
    static Typeface wufourTypeface(int face, int weight) {
        int slot = face * 3 + weightStep(weight);
        if (wufourTried[slot]) return wufourFaces[slot];
        Context c = ctx();
        if (c == null) return null;
        wufourTried[slot] = true;
        try {
            AssetManager assets = c.getAssets();
            if (Build.VERSION.SDK_INT >= 29) {
                FontFamily primary = new FontFamily.Builder(new Font.Builder(assets, fontFile(face, weight)).build()).build();
                Typeface.CustomFallbackBuilder chain = new Typeface.CustomFallbackBuilder(primary);
                try {
                    chain.addCustomFallback(new FontFamily.Builder(new Font.Builder(assets, fontFile(1 - face, weight)).build()).build());
                } catch (Exception ignored) {
                    // The other face is missing: the system fills in its glyphs.
                }
                wufourFaces[slot] = chain.setSystemFallback("sans-serif").build();
            } else {
                wufourFaces[slot] = Typeface.createFromAsset(assets, fontFile(face, weight));
            }
        } catch (Exception e) {
            wufourFaces[slot] = null; // no such asset: the system font, below
        }
        return wufourFaces[slot];
    }

    /**
     * The typeface for a face at a weight. Our faces come from the assets (weights already
     * snapped to 400, 500 or 700 by zui); a face whose file is missing falls back to the system
     * font, as before the fonts existed. Monospace is the system monospace.
     */
    static Typeface typeface(int weight, int face) {
        int key = weight * 4 + face;
        Typeface t = typefaces.get(key);
        if (t == null) {
            if (face != FACE_MONO) t = wufourTypeface(face, weight);
            if (t == null) {
                Typeface base = face == FACE_MONO ? Typeface.MONOSPACE : Typeface.DEFAULT;
                t = Build.VERSION.SDK_INT >= 28 ? Typeface.create(base, weight, false) : Typeface.create(base, weight >= 600 ? Typeface.BOLD : Typeface.NORMAL);
            }
            typefaces.put(key, t);
        }
        return t;
    }

    static int gravity(int align) {
        return (align == 1 ? Gravity.CENTER_HORIZONTAL : align == 2 ? Gravity.RIGHT : Gravity.LEFT) | Gravity.TOP;
    }

    static void styleText(TextView t, float size, int weight, float lineHeight, int face, int color, int align) {
        t.setTextSize(TypedValue.COMPLEX_UNIT_PX, size * density);
        t.setTypeface(typeface(weight, face));
        t.setTextColor(color);
        t.setGravity(gravity(align));
        t.setTextAlignment(View.TEXT_ALIGNMENT_GRAVITY);
        int lh = Math.round(lineHeight * density);
        if (Build.VERSION.SDK_INT >= 28) t.setLineHeight(lh);
        else t.setLineSpacing(lh - t.getPaint().getFontMetricsInt(null), 1f);
    }

    static void text(int id, String s, float size, int weight, float lineHeight, int face, int maxLines, int color, int align) {
        TextView t = (TextView) views.get(id);
        t.setText(s);
        styleText(t, size, weight, lineHeight, face, color, align);
        t.setMaxLines(maxLines > 0 ? maxLines : Integer.MAX_VALUE);
        t.setEllipsize(maxLines > 0 ? TextUtils.TruncateAt.END : null);
    }

    static void input(int id, String value, String placeholder, float size, int weight, float lineHeight, int face, int color, int align) {
        EditText e = (EditText) views.get(id);
        if (!e.getText().toString().equals(value)) {
            e.setTag(Boolean.TRUE); // not a user edit
            e.setText(value);
            e.setSelection(value.length());
            e.setTag(null);
        }
        e.setHint(placeholder);
        styleText(e, size, weight, lineHeight, face, color, align);
        // Text in the middle of the field, as on the web and iOS; a text area's from the top.
        boolean area = (e.getInputType() & InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0;
        e.setGravity((gravity(align) & Gravity.HORIZONTAL_GRAVITY_MASK) | (area ? Gravity.TOP : Gravity.CENTER_VERTICAL));
        e.setHintTextColor((Math.round(Color.alpha(color) * 0.45f) << 24) | (color & 0xffffff));
    }

    static void content(int id, float w, float h) {
        View c = container(id);
        ViewGroup.LayoutParams p = c.getLayoutParams();
        p.width = Math.round(w * density);
        p.height = Math.round(h * density);
        c.setLayoutParams(p);
    }

    /** End of a zui frame: lay out everything that changed in one pass. */
    static void commit() {
        root.requestLayout();
        root.invalidate();
    }

    static void transform(int id, float rotate, float tilt, float perspective, boolean hasOrigin, float ox, float oy) {
        View v = views.get(id);
        if (hasOrigin) {
            v.setPivotX(ox * density);
            v.setPivotY(oy * density);
        } else if (Build.VERSION.SDK_INT >= 28) {
            v.resetPivot();
        }
        v.setRotation(rotate);
        v.setRotationX(tilt);
        // setCameraDistance is not in pixels: View divides it by densityDpi and the renderer's
        // camera works in units of 72 px. So `perspective` dp is perspective * density px, times
        // densityDpi / 72.
        if (perspective > 0) v.setCameraDistance(perspective * density * (density * 160f) / 72f);
    }

    static void clip(int id, boolean on) {
        View v = views.get(id);
        v.setOutlineProvider(ZuiStyle.ROUND);
        v.setClipToOutline(on);
    }

    static void pointer(int id, boolean on) {
        View v = views.get(id);
        if (!on) {
            v.setOnTouchListener(null);
            return;
        }
        v.setOnTouchListener((view, e) -> {
            long t = e.getEventTime();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN: {
                    int i = e.getActionIndex();
                    nativePointer(id, POINTER_DOWN, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                }
                case MotionEvent.ACTION_MOVE:
                    for (int i = 0; i < e.getPointerCount(); i++)
                        nativePointer(id, POINTER_MOVE, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_POINTER_UP: {
                    int i = e.getActionIndex();
                    nativePointer(id, POINTER_UP, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                }
                case MotionEvent.ACTION_CANCEL:
                    for (int i = 0; i < e.getPointerCount(); i++)
                        nativePointer(id, POINTER_CANCEL, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
            }
            return true;
        });
    }

    static void unwant(String url) {
        wanted.computeIfPresent(url, (k, n) -> n > 1 ? n - 1 : null);
    }

    static void image(int id, String address, String headers) {
        // Pictures are kept by address and headers: one fetched with a token is not shown in
        // place of the same address without it.
        final String url = headers.isEmpty() ? address : address + "\n" + headers;
        ImageView v = (ImageView) views.get(id);
        if (url.equals(v.getTag())) return;
        if (v.getTag() instanceof String) unwant((String) v.getTag());
        v.setTag(url);
        Bitmap cached = bitmaps.get(url);
        if (cached != null) {
            v.setImageBitmap(cached);
            return;
        }
        v.setImageDrawable(null);
        wanted.merge(url, 1, Integer::sum);
        ArrayList<ImageView> list = waiting.get(url);
        if (list != null) {
            list.add(v); // already downloading
            return;
        }
        list = new ArrayList<>();
        list.add(v);
        waiting.put(url, list);
        loader.execute(() -> {
            Bitmap b = null;
            if (!wanted.containsKey(url)) {
                activity.runOnUiThread(() -> waiting.remove(url));
                return;
            }
            // A picture in the address itself (a photo just taken, as a data: URL).
            if (address.startsWith("data:")) {
                try {
                    byte[] bytes = android.util.Base64.decode(address.substring(address.indexOf(',') + 1), android.util.Base64.DEFAULT);
                    b = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                } catch (Exception ignored) {
                }
            } else try {
                HttpURLConnection c = (HttpURLConnection) new URL(address).openConnection();
                c.setConnectTimeout(10000);
                c.setReadTimeout(15000);
                c.setUseCaches(true);
                // Request headers (a Bearer token), one "name: value" line each.
                for (String line : headers.split("\n")) {
                    int at = line.indexOf(": ");
                    if (at > 0) c.setRequestProperty(line.substring(0, at), line.substring(at + 2));
                }
                try (InputStream in = c.getInputStream()) {
                    b = BitmapFactory.decodeStream(in);
                } finally {
                    c.disconnect();
                }
            } catch (Exception ignored) {
                // Missing tiles stay blank; the map keeps working.
            }
            final Bitmap bitmap = b;
            if (bitmap != null) bitmaps.put(url, bitmap);
            activity.runOnUiThread(() -> {
                ArrayList<ImageView> got = waiting.remove(url);
                if (bitmap == null || got == null) return;
                for (ImageView w : got) {
                    if (url.equals(w.getTag())) w.setImageBitmap(bitmap);
                }
            });
        });
    }

    static void path(int id, float[] points, int color, float width, float dashOn, float dashOff, boolean round, int fill) {
        ((ZuiPath) views.get(id)).set(points, color, width, dashOn, dashOff, round, fill, density);
    }

    // ---- Effects: network, timers, location, speech ----

    static void fetch(int id, String method, String url, byte[] body, String contentType, String headers) {
        network.execute(() -> {
            int status = 0;
            byte[] out = new byte[0];
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(30000);
                c.setRequestMethod(method);
                for (String line : headers.split("\n")) {
                    int at = line.indexOf(": ");
                    if (at > 0) c.setRequestProperty(line.substring(0, at), line.substring(at + 2));
                }
                if (body.length > 0) {
                    c.setDoOutput(true);
                    c.setRequestProperty("Content-Type", contentType);
                    try (OutputStream o = c.getOutputStream()) {
                        o.write(body);
                    }
                }
                status = c.getResponseCode();
                InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                if (in != null) {
                    try (InputStream s = in) {
                        ByteArrayOutputStream buf = new ByteArrayOutputStream();
                        byte[] chunk = new byte[16384];
                        for (int n; (n = s.read(chunk)) > 0; ) buf.write(chunk, 0, n);
                        out = buf.toByteArray();
                    }
                }
                c.disconnect();
            } catch (Exception ignored) {
                status = 0; // unreachable: the app shows its own message
            }
            final int st = status;
            final byte[] b = out;
            main.post(() -> nativeFetchDone(id, st, b));
        });
    }

    static void timer(int id, int ms) {
        main.postDelayed(() -> nativeTimer(id), ms);
    }

    static LocationManager locations;
    static LocationListener listener;
    static boolean locationWanted;
    static final int LOCATION_REQUEST = 7001;

    static void location(boolean on) {
        locationWanted = on;
        if (!on) {
            if (listener != null) locations.removeUpdates(listener);
            listener = null;
            return;
        }
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[] {Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_REQUEST);
            return;
        }
        startLocation();
    }

    /** From the activity, after the permission prompt. */
    static void locationPermission(boolean granted) {
        if (!locationWanted) return;
        if (granted) startLocation(); else nativeLocationError(true);
    }

    @SuppressWarnings("MissingPermission")
    static void startLocation() {
        if (listener != null) return;
        locations = (LocationManager) activity.getSystemService(Context.LOCATION_SERVICE);
        listener = l -> nativeLocation(l.getLatitude(), l.getLongitude(), l.hasAccuracy() ? l.getAccuracy() : 0,
                l.hasBearing() ? l.getBearing() : Float.NaN, l.hasSpeed() ? l.getSpeed() : Float.NaN);
        boolean any = false;
        // Android 12+ fuses GPS, Wi-Fi and cell itself; before that, both providers.
        String[] providers = Build.VERSION.SDK_INT >= 31 && locations.hasProvider(LocationManager.FUSED_PROVIDER)
                ? new String[] {LocationManager.FUSED_PROVIDER}
                : new String[] {LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER};
        for (String p : providers) {
            if (!locations.isProviderEnabled(p)) continue;
            locations.requestLocationUpdates(p, 1000, 0, listener, Looper.getMainLooper());
            android.location.Location last = locations.getLastKnownLocation(p);
            if (last != null) listener.onLocationChanged(last);
            any = true;
        }
        if (!any) nativeLocationError(false);
    }

    static TextToSpeech tts;
    static boolean ttsReady;
    static String pendingSpeech, pendingLang;

    static void speak(String text, String lang) {
        if (tts == null) {
            pendingSpeech = text;
            pendingLang = lang;
            tts = new TextToSpeech(activity, status -> {
                ttsReady = status == TextToSpeech.SUCCESS;
                if (ttsReady && pendingSpeech != null) say(pendingSpeech, pendingLang);
                pendingSpeech = null;
            });
            return;
        }
        if (ttsReady) say(text, lang);
    }

    static void say(String text, String lang) {
        tts.setLanguage(java.util.Locale.forLanguageTag(lang));
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "zui");
    }

    static void setLink(String l) {
        link = l;
    }

    /** The image's colour matrix (CSS saturate/contrast/brightness, computed in Zig). */
    static void imageFilter(int id, float[] m) {
        ImageView v = (ImageView) views.get(id);
        boolean identity = m[0] == 1 && m[6] == 1 && m[12] == 1 && m[1] == 0 && m[4] == 0;
        v.setColorFilter(identity ? null : new android.graphics.ColorMatrixColorFilter(m));
    }

    // ---- Storage: SharedPreferences; secure values encrypted with an Android Keystore key ----

    static android.content.SharedPreferences prefs() {
        return prefs(ctx());
    }

    /** Also from ZuiAuthProvider, which may run before (or without) the activity. */
    static android.content.SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("zui", Context.MODE_PRIVATE);
    }

    static javax.crypto.SecretKey keystoreKey() throws Exception {
        java.security.KeyStore ks = java.security.KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias("zui")) {
            javax.crypto.KeyGenerator g = javax.crypto.KeyGenerator.getInstance(android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            g.init(new android.security.keystore.KeyGenParameterSpec.Builder("zui",
                    android.security.keystore.KeyProperties.PURPOSE_ENCRYPT | android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build());
            g.generateKey();
        }
        return ((java.security.KeyStore.SecretKeyEntry) ks.getEntry("zui", null)).getSecretKey();
    }

    static String storageGet(String key, boolean secure) {
        return storageGet(ctx(), key, secure);
    }

    static String storageGet(Context cx, String key, boolean secure) {
        String v = prefs(cx).getString((secure ? "s:" : "p:") + key, null);
        if (v == null || !secure) return v;
        try {
            byte[] all = android.util.Base64.decode(v, android.util.Base64.NO_WRAP);
            javax.crypto.Cipher c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
            c.init(javax.crypto.Cipher.DECRYPT_MODE, keystoreKey(), new javax.crypto.spec.GCMParameterSpec(128, all, 0, 12));
            return new String(c.doFinal(all, 12, all.length - 12), java.nio.charset.StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null; // the key changed (device restored elsewhere): sign in again
        }
    }

    static void storageSet(String key, String value, boolean secure) {
        String stored = value;
        if (secure) {
            try {
                javax.crypto.Cipher c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
                c.init(javax.crypto.Cipher.ENCRYPT_MODE, keystoreKey());
                byte[] iv = c.getIV();
                byte[] ct = c.doFinal(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                byte[] all = new byte[iv.length + ct.length];
                System.arraycopy(iv, 0, all, 0, iv.length);
                System.arraycopy(ct, 0, all, iv.length, ct.length);
                stored = android.util.Base64.encodeToString(all, android.util.Base64.NO_WRAP);
            } catch (Exception e) {
                return; // never store a secret in the clear
            }
        }
        prefs().edit().putString((secure ? "s:" : "p:") + key, stored).apply();
    }

    static void storageRemove(String key, boolean secure) {
        prefs().edit().remove((secure ? "s:" : "p:") + key).apply();
    }

    /** At once (a sibling app asked: it reads again right after). */
    static void storageRemoveNow(Context cx, String key, boolean secure) {
        prefs(cx).edit().remove((secure ? "s:" : "p:") + key).commit();
    }

    /** The foreground service that keeps the process (and the location listener) alive. */
    static void backgroundLocation(boolean on, String title, String text) {
        Intent intent = new Intent(activity, ZuiLocationService.class);
        if (!on) {
            activity.stopService(intent);
            return;
        }
        // Android 13+: the ongoing notification needs this permission.
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 7002);
        }
        intent.putExtra("title", title).putExtra("text", text);
        activity.startForegroundService(intent);
    }

    // ---- Notifications: normal, and urgent (full-screen over the lock screen, insistent alarm) ----

    static final String CHANNEL_NORMAL = "zui-normal", CHANNEL_URGENT = "zui-urgent";

    static void notify(int id, String title, String body, boolean urgent) {
        Context activity = ctx();
        android.app.NotificationManager nm = activity.getSystemService(android.app.NotificationManager.class);
        if (Zui.activity != null && Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Zui.activity.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 7003);
        }
        if (nm.getNotificationChannel(CHANNEL_NORMAL) == null) {
            nm.createNotificationChannel(new android.app.NotificationChannel(CHANNEL_NORMAL, "Notifications", android.app.NotificationManager.IMPORTANCE_DEFAULT));
            android.app.NotificationChannel urgentChannel = new android.app.NotificationChannel(CHANNEL_URGENT, "Alerts", android.app.NotificationManager.IMPORTANCE_HIGH);
            urgentChannel.setSound(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM),
                    new android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_ALARM).build());
            urgentChannel.enableVibration(true);
            urgentChannel.setBypassDnd(true);
            nm.createNotificationChannel(urgentChannel);
        }
        Intent open = new Intent(activity, ZuiActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        open.putExtra("zui_alert", urgent);
        android.app.PendingIntent tap = android.app.PendingIntent.getActivity(activity, id, open, android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT);
        android.app.Notification.Builder b = new android.app.Notification.Builder(activity, urgent ? CHANNEL_URGENT : CHANNEL_NORMAL)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new android.app.Notification.BigTextStyle().bigText(body))
                .setSmallIcon(activity.getApplicationInfo().icon != 0 ? activity.getApplicationInfo().icon : android.R.drawable.ic_dialog_info)
                .setContentIntent(tap)
                .setAutoCancel(true);
        if (urgent) {
            b.setCategory(android.app.Notification.CATEGORY_ALARM).setFullScreenIntent(tap, true).setOngoing(true);
        }
        android.app.Notification n = b.build();
        if (urgent) n.flags |= android.app.Notification.FLAG_INSISTENT;
        nm.notify(id, n);
    }

    static void cancelNotify(int id) {
        ctx().getSystemService(android.app.NotificationManager.class).cancel(id);
    }

    /** A video view shows stream `stream` (a local camera, or a remote one). */
    static void video(int id, int stream, boolean mirror, boolean cover) {
        ZuiMedia.video(id, stream, mirror, cover);
    }

    static void ringCall(String id, String name, boolean video, String label) {
        ZuiCallService.label(id, label);
        ZuiCallService.ring(ctx(), id, name, video);
    }

    static void startCall(String id, String name, boolean video, String label) {
        ZuiCallService.label(id, label);
        ZuiCallService.outgoing(ctx(), id, name, video);
    }

    static void callConnected(String id) {
        ZuiCallService.connected(id);
    }

    static void endCall(String id) {
        ZuiCallService.end(ctx(), id);
    }

    static void widgetUpdate(String title, String l1, String l2, String l3) {
        ZuiWidget.update(ctx(), title, l1, l2, l3);
    }

    static void openSocket(int id, String url) {
        ZuiSocket s = new ZuiSocket(id, url);
        sockets.put(id, s);
        s.start();
    }

    static void sendSocket(int id, String text) {
        ZuiSocket s = sockets.get(id);
        if (s != null) s.sendText(text);
    }

    static void closeSocket(int id) {
        ZuiSocket s = sockets.remove(id);
        if (s != null) s.close();
    }

    static void copy(String text) {
        android.content.ClipboardManager c = (android.content.ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
        c.setPrimaryClip(android.content.ClipData.newPlainText("", text));
    }

    static void openUrl(String url) {
        try {
            activity.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)));
        } catch (Exception ignored) {
            // nothing on the phone opens it
        }
    }

    /** UTF-16 index → UTF-8 byte offset, and back (the app counts bytes). */
    static int bytes(String s, int units) {
        units = Math.max(0, Math.min(units, s.length()));
        return s.substring(0, units).getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
    }

    static int units(String s, int bytes) {
        int b = 0, i = 0;
        while (i < s.length() && b < bytes) {
            int c = s.codePointAt(i);
            b += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
            i += Character.charCount(c);
        }
        return i;
    }

    static long selection(int id) {
        View v = views.get(id);
        if (!(v instanceof EditText)) return -1;
        EditText e = (EditText) v;
        String t = e.getText().toString();
        return ((long) bytes(t, e.getSelectionStart()) << 32) | (bytes(t, e.getSelectionEnd()) & 0xffffffffL);
    }

    static void select(int id, int start, int end) {
        View v = views.get(id);
        if (!(v instanceof EditText)) return;
        EditText e = (EditText) v;
        String t = e.getText().toString();
        focus(id);
        try {
            e.setSelection(units(t, start), units(t, end));
        } catch (IndexOutOfBoundsException ignored) {
        }
    }

    static void focus(int id) {
        View v = views.get(id);
        if (v == null) return;
        v.requestFocus();
        ((InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE)).showSoftInput(v, InputMethodManager.SHOW_IMPLICIT);
    }

    static void requestFrame() {
        if (frameRequested) return;
        frameRequested = true;
        Choreographer.getInstance().postFrameCallback(time -> {
            frameRequested = false;
            nativeFrame(time);
        });
    }

    static void rootBackground(int argb) {
        root.setBackgroundColor(argb);
        // Dark system-bar icons on light backgrounds, light icons on dark ones.
        boolean light = Color.alpha(argb) > 0 && (0.299 * Color.red(argb) + 0.587 * Color.green(argb) + 0.114 * Color.blue(argb)) > 150;
        Window w = activity.getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                c.setSystemBarsAppearance(light ? mask : 0, mask);
            }
        } else {
            int flags = w.getDecorView().getSystemUiVisibility();
            int lightFlags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
            w.getDecorView().setSystemUiVisibility(light ? flags | lightFlags : flags & ~lightFlags);
        }
    }

    /** Size of `s` in points, packed as (float bits of width << 32) | float bits of height. */
    static long measure(String s, float size, int weight, float lineHeight, int face, int maxLines, float maxWidth) {
        paint.setTextSize(size * density);
        paint.setTypeface(typeface(weight, face));
        int avail = Float.isInfinite(maxWidth) ? 1 << 20 : Math.max(1, (int) Math.floor(maxWidth * density));
        StaticLayout layout = StaticLayout.Builder.obtain(s, 0, s.length(), paint, avail)
                .setIncludePad(false)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build();
        int lines = layout.getLineCount();
        if (maxLines > 0) lines = Math.min(lines, maxLines);
        float widest = 0;
        for (int i = 0; i < lines; i++) widest = Math.max(widest, layout.getLineWidth(i));
        // One spare pixel so rounding the frame to pixels never forces an extra line break.
        float w = s.isEmpty() ? 0 : (float) (Math.ceil(widest) + 1) / density;
        float h = lines * Math.round(lineHeight * density) / density;
        return ((long) Float.floatToRawIntBits(w) << 32) | (Float.floatToRawIntBits(h) & 0xffffffffL);
    }
}
