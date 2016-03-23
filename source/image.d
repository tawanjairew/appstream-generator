/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.image;

import std.stdio;
import std.string;
import std.conv : to;
import std.path : baseName;
import std.math;
import core.stdc.stdarg;
import core.stdc.stdio;
import c.cairo;
import c.gdlib;
import c.rsvg;

import gi.glibtypes;
import gi.glib;

import ag.logging;


enum ImageFormat {
    UNKNOWN,
    PNG,
    JPEG,
    GIF,
    SVG,
    SVGZ
}

// thread-local
private string lastErrorMsg;

extern(C) nothrow
private void gdLibError (int code, const(char) *msg, va_list args)
{
    import std.outbuffer;

    // Terrible...
    // LibGDs error handling sucks, and this code does too.
    try {
        auto buf = new OutBuffer ();
        auto strMsg = to!string (fromStringz (msg));
        buf.vprintf (strMsg, args);

        // don't silently override a messge, instead dump it to the log
        if (lastErrorMsg !is null)
            logError (lastErrorMsg);

        lastErrorMsg = buf.toString ().dup;
    } catch {}
}

class Image
{

private:
    gdImagePtr gdi;

public:

    private void throwError (string msg)
    {
        if (lastErrorMsg is null) {
            throw new Exception (msg);
        } else {
            auto errMsg = lastErrorMsg.strip ();
            lastErrorMsg = null;
            throw new Exception (format ("%s %s", msg, errMsg));
        }
    }

    this (string fname)
    {
        gdSetErrorMethod (&gdLibError);
        gdi = gdImageCreateFromFile (fname.toStringz ());
        if (gdi == null) {
            throwError (format ("Unable to open image '%s'.", baseName (fname)));
        }
    }

    this (string data, ImageFormat ikind)
    {
        import core.stdc.string : strlen;

        //gdSetErrorMethod (&gdLibError);

        auto imgBytes = cast(byte[]) data;
        auto imgDSize = to!int (byte.sizeof * imgBytes.length);

        switch (ikind) {
            case ImageFormat.PNG:
                gdi = gdImageCreateFromPngPtr (imgDSize, cast(void*) imgBytes);
                break;
            case ImageFormat.JPEG:
                gdi = gdImageCreateFromJpegPtr (imgDSize, cast(void*) imgBytes);
                break;
            case ImageFormat.GIF:
                gdi = gdImageCreateFromGifPtr (imgDSize, cast(void*) imgBytes);
                break;
            default:
                throw new Exception (format ("Unable to open image of type '%s'.", to!string (ikind)));
        }
        if (gdi == null)
            throwError ("Failed to load image data. The image might be invalid.");
    }

    ~this ()
    {
        if (gdi !is null)
            gdImageDestroy (gdi);
    }

    @property
    uint width ()
    {
        return gdi.sx;
    }

    @property
    uint height ()
    {
        return gdi.sy;
    }

    /**
     * Scale the image to the given size.
     */
    void scale (uint newWidth, uint newHeight)
    {
        gdImageSetInterpolationMethod (gdi, gdInterpolationMethod.BILINEAR_FIXED);

        auto resImg = gdImageScale (gdi, newWidth, newHeight);
        if (resImg is null)
            throwError ("Scaling of image failed.");

        // set our current image to the scaled version
        gdImageDestroy (gdi);
        gdi = resImg;
    }

    /**
     * Scale the image to the given width, preserving
     * its aspect ratio.
     */
    void scaleToWidth (uint newWidth)
    {
        import std.math;

        float scaleFactor = width / newWidth;
        uint newHeight = to!uint (floor (height * scaleFactor));

        scale (newWidth, newHeight);
    }

    /**
     * Scale the image to the given height, preserving
     * its aspect ratio.
     */
    void scaleToHeight (uint newHeight)
    {
        import std.math;

        float scaleFactor = height / newHeight;
        uint newWidth = to!uint (floor (width * scaleFactor));

        scale (newWidth, newHeight);
    }

    /**
     * Scale the image to fir in a square with the given edge length,
     * and keep its aspect ratio.
     */
    void scaleToFit (uint size)
    {
        if (height > width) {
            scaleToHeight (size);
        } else {
            scaleToWidth (size);
        }
    }

    void savePng (File f)
    {
        gdImageSaveAlpha (gdi, 1);
        gdImagePng (gdi, f.getFP ());
    }
}

class Canvas
{

private:
    cairo_surface_p srf;
    cairo_p cr;

public:

    this (int w, int h)
    {
         srf = cairo_image_surface_create (cairo_format_t.FORMAT_ARGB32, w, h);
         cr = cairo_create (srf);
    }

    ~this ()
    {
        if (cr !is null)
            cairo_destroy (cr);
        if (srf !is null)
            cairo_surface_destroy (srf);
    }

    void renderSvg (string svgData)
    {
        auto handle = rsvg_handle_new ();
        scope (exit) g_object_unref (handle);

        auto svgBytes = cast(ubyte[]) svgData;
        auto svgDSize = ubyte.sizeof * svgBytes.length;

        GError *error = null;
        rsvg_handle_write (handle, cast(ubyte*) svgBytes, svgDSize, &error);
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);
            throw new Exception (to!string (msg));
        }

        rsvg_handle_close (handle, &error);
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);
            throw new Exception (to!string (msg));
        }

        RsvgDimensionData dims;
        rsvg_handle_get_dimensions (handle, &dims);

        auto w = cairo_image_surface_get_width (srf);
        auto h = cairo_image_surface_get_height (srf);

        // cairo_translate (cr, (w - dims.width) / 2, (h - dims.height) / 2);
        cairo_scale (cr, w / dims.width, h / dims.height);

        cr.cairo_save ();
        scope (exit) cr.cairo_restore ();
        if (!rsvg_handle_render_cairo (handle, cr))
            throw new Exception ("Rendering of SVG images failed!");
    }

    void savePng (string fname)
    {
        auto status = cairo_surface_write_to_png (srf, fname.toStringz ());
        if (status != cairo_status_t.STATUS_SUCCESS)
            throw new Exception (format ("Could not save canvas to PNG: %s", to!string (status)));
    }
}

unittest
{
    import std.file : getcwd;
    import std.path : buildPath;
    writeln ("TEST: ", "Image");

    auto sampleImgPath = buildPath (getcwd(), "test", "samples", "appstream-logo.png");
    writeln ("Loading image (file)");
    auto img = new Image (sampleImgPath);

    writeln ("Scaling image");
    assert (img.width == 134);
    assert (img.height == 132);
    img.scale (64, 64);
    assert (img.width == 64);
    assert (img.height == 64);

    writeln ("Storing image");
    auto f = File ("/tmp/ag-ut_test.png", "w");
    img.savePng (f);

    writeln ("Loading image (data)");
    string data;
    f = File (sampleImgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= to!string (f.rawRead (buf));
    }
    img = new Image (data, ImageFormat.PNG);
    writeln ("Scaling image (data)");
    img.scale (64, 64);
    writeln ("Storing image (data)");
    f = File ("/tmp/ag-ut_test.png", "w");
    img.savePng (f);

    writeln ("Rendering SVG");
    auto sampleSvgPath = buildPath (getcwd(), "test", "samples", "table.svgz");
    data = "";
    f = File (sampleSvgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= to!string (f.rawRead (buf));
    }
    auto cv = new Canvas (512, 512);
    cv.renderSvg (data);
    writeln ("Saving rendered PNG");
    cv.savePng ("/tmp/ag-svgrender_test1.png");
}