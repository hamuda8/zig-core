package com.wufour.zui;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;

/** Lines and filled shapes through points zui gives: route lines on the map, icons. */
public final class ZuiPath extends View {
    private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private boolean hasStroke, hasFill;

    public ZuiPath(Context context) {
        super(context);
        stroke.setStyle(Paint.Style.STROKE);
        fill.setStyle(Paint.Style.FILL);
    }

    /** Points are x, y pairs in points (dp), scaled by `density` here; a NaN x starts a new
     *  sub-path. A fill color with alpha 0 means no fill, a width of 0 no stroke. */
    void set(float[] points, int color, float width, float dashOn, float dashOff, boolean round, int fillColor, float density) {
        path.reset();
        boolean move = true;
        hasFill = (fillColor >>> 24) != 0;
        for (int i = 0; i + 1 < points.length; i += 2) {
            if (Float.isNaN(points[i])) {
                if (hasFill && !move) path.close();
                move = true;
                continue;
            }
            float x = points[i] * density, y = points[i + 1] * density;
            if (move) path.moveTo(x, y); else path.lineTo(x, y);
            move = false;
        }
        if (hasFill && !move) path.close();
        fill.setColor(fillColor);
        hasStroke = width > 0;
        stroke.setColor(color);
        stroke.setStrokeWidth(width * density);
        stroke.setStrokeCap(round ? Paint.Cap.ROUND : Paint.Cap.BUTT);
        stroke.setStrokeJoin(round ? Paint.Join.ROUND : Paint.Join.MITER);
        stroke.setPathEffect(dashOn > 0 ? new DashPathEffect(new float[] {dashOn * density, dashOff * density}, 0) : null);
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        if (hasFill) canvas.drawPath(path, fill);
        if (hasStroke) canvas.drawPath(path, stroke);
    }
}
