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
import c.rsvg;
import c.gdkpixbuf;

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

class Image
{

private:
    GdkPixbuf pix;

public:

    private void throwGError (GError *error, string pretext = null)
    {
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);

            if (pretext is null)
                throw new Exception (to!string (msg));
            else
                throw new Exception (format ("%s: %s", pretext, to!string (msg)));
        }
    }

    this (string fname)
    {
        GError *error = null;
        pix = gdk_pixbuf_new_from_file (fname.toStringz (), &error);
        throwGError (error, format ("Unable to open image '%s'", baseName (fname)));
    }

    this (ubyte[] imgBytes, ImageFormat ikind)
    {
        import gi.gio;
        import gio.MemoryInputStream;

        auto istream = new MemoryInputStream ();
        istream.addData (imgBytes, null);

        GError *error = null;
        pix = gdk_pixbuf_new_from_stream (cast(GInputStream*) istream.getMemoryInputStreamStruct (), null, &error);
        throwGError (error, "Failed to load image data");
    }

    ~this ()
    {
        if (pix !is null)
            g_object_unref (pix);
    }

    @property
    uint width ()
    {
        return pix.gdk_pixbuf_get_width ();
    }

    @property
    uint height ()
    {
        return pix.gdk_pixbuf_get_height ();
    }

    /**
     * Scale the image to the given size.
     */
    void scale (uint newWidth, uint newHeight)
    {
        auto resPix = gdk_pixbuf_scale_simple (pix, newWidth, newHeight, GdkInterpType.BILINEAR);
        if (resPix is null)
            throw new Exception (format ("Scaling of image to %sx%s failed.", newWidth, newHeight));

        // set our current image to the scaled version
        g_object_unref (pix);
        pix = resPix;
    }

    /**
     * Scale the image to the given width, preserving
     * its aspect ratio.
     */
    void scaleToWidth (uint newWidth)
    {
        import std.math;

        float scaleFactor = cast(float) newWidth / cast (float) width;
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

        float scaleFactor = cast(float) newHeight / cast(float) height;
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

    void savePng (string fname)
    {
        GError *error = null;
        gdk_pixbuf_save (pix, fname.toStringz (), "png", &error, null);
        throwGError (error);
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

    void renderSvg (ubyte[] svgBytes)
    {
        auto handle = rsvg_handle_new ();
        scope (exit) g_object_unref (handle);

        auto svgBSize = ubyte.sizeof * svgBytes.length;
        GError *error = null;
        rsvg_handle_write (handle, cast(ubyte*) svgBytes, svgBSize, &error);
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

        auto w = cast(double) cairo_image_surface_get_width (srf);
        auto h = cast(double) cairo_image_surface_get_height (srf);

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
    img.savePng ("/tmp/ag-iscale_test.png");

    writeln ("Loading image (data)");
    ubyte[] data;
    auto f = File (sampleImgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= f.rawRead (buf);
    }

    img = new Image (data, ImageFormat.PNG);
    writeln ("Scaling image (data)");
    img.scale (124, 124);
    writeln ("Storing image (data)");
    img.savePng ("/tmp/ag-iscale-d_test.png");

    writeln ("Rendering SVG");
    auto sampleSvgPath = buildPath (getcwd(), "test", "samples", "table.svgz");
    data = null;
    f = File (sampleSvgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= f.rawRead (buf);
    }
    auto cv = new Canvas (512, 512);
    cv.renderSvg (data);
    writeln ("Saving rendered PNG");
    cv.savePng ("/tmp/ag-svgrender_test1.png");
}
