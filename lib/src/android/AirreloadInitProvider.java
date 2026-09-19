package dev.airreload.runtime;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;

/**
 * Starts the debug-only Airreload tunnel from the Android process, not the Dart
 * isolate. Content providers are created once per process, so hot restart cannot
 * tear this down.
 */
public final class AirreloadInitProvider extends ContentProvider {
  @Override
  public boolean onCreate() {
    Context context = getContext();
    if (context == null) {
      return false;
    }
    AirreloadNativeTunnel.start(context.getApplicationContext());
    return true;
  }

  @Override
  public Cursor query(
      Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
    return null;
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
  public int delete(Uri uri, String selection, String[] selectionArgs) {
    return 0;
  }

  @Override
  public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
    return 0;
  }
}
