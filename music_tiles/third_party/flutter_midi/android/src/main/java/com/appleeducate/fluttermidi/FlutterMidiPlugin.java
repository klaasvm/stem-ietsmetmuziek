package com.appleeducate.fluttermidi;

import cn.sherlock.com.sun.media.sound.SF2Soundbank;
import cn.sherlock.com.sun.media.sound.SoftSynthesizer;
import android.util.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.io.File;
import java.io.IOException;
import jp.kshoji.javax.sound.midi.InvalidMidiDataException;
import jp.kshoji.javax.sound.midi.MidiUnavailableException;
import jp.kshoji.javax.sound.midi.Receiver;
import jp.kshoji.javax.sound.midi.ShortMessage;

/** FlutterMidiPlugin */
public class FlutterMidiPlugin implements MethodCallHandler, FlutterPlugin {
  private static final String TAG = "FlutterMidiPlugin";
  private SoftSynthesizer synth;
  private Receiver recv;
  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    Log.d(TAG, "onAttachedToEngine");
    channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_midi");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    Log.d(TAG, "onDetachedFromEngine");
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
  }

  @Override
  public void onMethodCall(MethodCall call, Result result) {
    final long start = System.currentTimeMillis();
    Log.d(TAG, "onMethodCall: method=" + call.method);
    if (call.method.equals("prepare_midi")) {
      try {
        String _path = call.argument("path");
        Log.d(TAG, "prepare_midi path=" + _path);
        if (_path == null) {
          Log.e(TAG, "prepare_midi failed: missing path");
          result.error("invalid_args", "Missing soundfont path", null);
          return;
        }
        File _file = new File(_path);
        Log.d(TAG, "prepare_midi exists=" + _file.exists() + " size=" + _file.length());
        SF2Soundbank sf = new SF2Soundbank(_file);
        synth = new SoftSynthesizer();
        synth.open();
        synth.loadAllInstruments(sf);
        synth.getChannels()[0].programChange(0);
        synth.getChannels()[1].programChange(1);
        recv = synth.getReceiver();
        Log.d(TAG, "prepare_midi success elapsedMs=" + (System.currentTimeMillis() - start));
        result.success("prepared");
      } catch (IOException e) {
        Log.e(TAG, "prepare_midi io_error", e);
        result.error("io_error", e.getMessage(), null);
      } catch (MidiUnavailableException e) {
        Log.e(TAG, "prepare_midi midi_unavailable", e);
        result.error("midi_unavailable", e.getMessage(), null);
      }
    } else if (call.method.equals("unmute")) {
      Log.d(TAG, "unmute requested (no-op on Android)");
      result.success("unmuted");
    } else if (call.method.equals("change_sound")) {
      try {
        String _path = call.argument("path");
        Log.d(TAG, "change_sound path=" + _path);
        if (_path == null) {
          Log.e(TAG, "change_sound failed: missing path");
          result.error("invalid_args", "Missing soundfont path", null);
          return;
        }
        File _file = new File(_path);
        Log.d(TAG, "change_sound exists=" + _file.exists() + " size=" + _file.length());
        SF2Soundbank sf = new SF2Soundbank(_file);
        synth = new SoftSynthesizer();
        synth.open();
        synth.loadAllInstruments(sf);
        synth.getChannels()[0].programChange(0);
        synth.getChannels()[1].programChange(1);
        recv = synth.getReceiver();
        Log.d(TAG, "change_sound success elapsedMs=" + (System.currentTimeMillis() - start));
        result.success("changed");
      } catch (IOException e) {
        Log.e(TAG, "change_sound io_error", e);
        result.error("io_error", e.getMessage(), null);
      } catch (MidiUnavailableException e) {
        Log.e(TAG, "change_sound midi_unavailable", e);
        result.error("midi_unavailable", e.getMessage(), null);
      }
    } else if (call.method.equals("play_midi_note")) {
      int _note = call.argument("note");
      Log.d(TAG, "play_midi_note note=" + _note + " recvReady=" + (recv != null));
      if (recv == null) {
        Log.e(TAG, "play_midi_note failed: recv not ready");
        result.error("not_ready", "Soundfont is not prepared", null);
        return;
      }
      try {
        ShortMessage msg = new ShortMessage();
        msg.setMessage(ShortMessage.NOTE_ON, 0, _note, 127);
        recv.send(msg, -1);
        Log.d(TAG, "play_midi_note success elapsedMs=" + (System.currentTimeMillis() - start));
        result.success("note_on");
      } catch (InvalidMidiDataException e) {
        Log.e(TAG, "play_midi_note invalid_midi", e);
        result.error("invalid_midi", e.getMessage(), null);
      }
    } else if (call.method.equals("stop_midi_note")) {
      int _note = call.argument("note");
      Log.d(TAG, "stop_midi_note note=" + _note + " recvReady=" + (recv != null));
      if (recv == null) {
        Log.e(TAG, "stop_midi_note failed: recv not ready");
        result.error("not_ready", "Soundfont is not prepared", null);
        return;
      }
      try {
        ShortMessage msg = new ShortMessage();
        msg.setMessage(ShortMessage.NOTE_OFF, 0, _note, 127);
        recv.send(msg, -1);
        Log.d(TAG, "stop_midi_note success elapsedMs=" + (System.currentTimeMillis() - start));
        result.success("note_off");
      } catch (InvalidMidiDataException e) {
        Log.e(TAG, "stop_midi_note invalid_midi", e);
        result.error("invalid_midi", e.getMessage(), null);
      }
    } else {
      Log.w(TAG, "Method not implemented: " + call.method);
      result.notImplemented();
    }
  }
}
