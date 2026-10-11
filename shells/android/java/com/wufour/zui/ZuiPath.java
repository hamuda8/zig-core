package com.wufour.zui;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;

/** A line through points zui gives (route lines on the map). */
public final class ZuiPath extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();

    public ZuiPath(Context context) {
        super(context);
        paint.setStyle(Paint.Style.STROKE);
    }

    /** Points are x, y pairs in points (dp); everything is scaled by `density` here. */
    void set(float[] points, int color, float width, float dashOn, float dashOff, boolean round, float density) {
        path.reset();
        for (int i = 0; i + 1 < points.length; i += 2) {
            float x = points[i] * density, y = points[i + 1] * density;
            if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
        }
        paint.setColor(color);
        paint.setStrokeWidth(width * density);
        paint.setStrokeCap(round ? Paint.Cap.ROUND : Paint.Cap.BUTT);
        paint.setStrokeJoin(round ? Paint.Join.ROUND : Paint.Join.MITER);
        paint.setPathEffect(dashOn > 0 ? new DashPathEffect(new float[] {dashOn * density, dashOff * density}, 0) : null);
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        canvas.drawPath(path, paint);
    }
}
