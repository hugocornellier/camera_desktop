#include "record_handler.h"

#include <cstdio>

// H-5: Maximum recording queue size.
// Bounds RAM consumed by the recording branch if the encoder falls behind
// (e.g., during an antivirus scan or CPU spike). Backpressure will propagate
// upstream rather than silently consuming all available memory.
static const guint64 kRecQueueMaxTimeNs = 3 * GST_SECOND;  // 3 s time limit
static const guint kRecQueueMaxBytes = 256 * 1024 * 1024;  // 256 MB hard cap

// Video encoder candidates in order of preference.
static const char* kEncoderCandidates[] = {
    "x264enc",
    "vah264enc",
    "vaapih264enc",
    "openh264enc",
};
static const int kNumEncoderCandidates = 4;

// Audio encoder candidates in order of preference.
static const char* kAudioEncoderCandidates[] = {
    "opusenc",
    "avenc_aac",
    "voaacenc",
    "lamemp3enc",
};
static const int kNumAudioEncoderCandidates = 4;

RecordHandler::RecordHandler()
    : pipeline_(nullptr),
      tee_(nullptr),
      queue_(nullptr),
      valve_(nullptr),
      videoconvert_(nullptr),
      encoder_(nullptr),
      h264parse_(nullptr),
      muxer_(nullptr),
      filesink_(nullptr),
      audio_source_(nullptr),
      audio_convert_(nullptr),
      audio_resample_(nullptr),
      audio_encoder_(nullptr),
      audio_queue_(nullptr),
      audio_valve_(nullptr),
      is_recording_(false),
      is_setup_(false),
      has_audio_(false),
      pending_stop_call_(nullptr) {}

RecordHandler::~RecordHandler() {
  if (pending_stop_call_) {
    g_object_unref(pending_stop_call_);
    pending_stop_call_ = nullptr;
  }
}

std::string RecordHandler::DetectEncoder() {
  for (int i = 0; i < kNumEncoderCandidates; i++) {
    GstElementFactory* factory =
        gst_element_factory_find(kEncoderCandidates[i]);
    if (factory) {
      gst_object_unref(factory);
      return kEncoderCandidates[i];
    }
  }
  return "";
}

std::string RecordHandler::DetectAudioEncoder() {
  for (int i = 0; i < kNumAudioEncoderCandidates; i++) {
    GstElementFactory* factory =
        gst_element_factory_find(kAudioEncoderCandidates[i]);
    if (factory) {
      gst_object_unref(factory);
      return kAudioEncoderCandidates[i];
    }
  }
  return "";
}

bool RecordHandler::Setup(GstElement* pipeline, GstElement* tee,
                          int width, int height, int fps, int video_bitrate,
                          int audio_bitrate, bool enable_audio,
                          GError** error) {
  if (is_setup_) return true;

  encoder_name_ = DetectEncoder();
  if (encoder_name_.empty()) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "No H.264 encoder available. Install gstreamer1.0-plugins-ugly "
                "(x264enc) or gstreamer1.0-vaapi (vaapih264enc).");
    return false;
  }

  pipeline_ = pipeline;
  tee_ = tee;

  // Create video recording branch elements.
  queue_ = gst_element_factory_make("queue", "rec_queue");
  valve_ = gst_element_factory_make("valve", "rec_valve");
  videoconvert_ = gst_element_factory_make("videoconvert", "rec_convert");
  encoder_ = gst_element_factory_make(encoder_name_.c_str(), "rec_encoder");
  h264parse_ = gst_element_factory_make("h264parse", "rec_h264parse");

  // H-6: prefer mp4mux so the output file is a genuine MP4 container.
  // Fall back to matroskamux if mp4mux is unavailable; the output extension
  // is set accordingly in camera.cc so the container and extension always match.
  muxer_ = gst_element_factory_make("mp4mux", "rec_mux");
  if (!muxer_) {
    muxer_ = gst_element_factory_make("matroskamux", "rec_mux");
    using_matroskamux_ = true;
  }

  filesink_ = gst_element_factory_make("filesink", "rec_filesink");

  if (!queue_ || !valve_ || !videoconvert_ || !encoder_ || !h264parse_ ||
      !muxer_ || !filesink_) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to create recording pipeline elements");
    return false;
  }

  // mp4mux/matroskamux expect byte-stream H.264; encoders link only through
  // h264parse (also sets stream-format for MP4).
  g_object_set(h264parse_, "config-interval", 1, nullptr);

  // Configure the valve to start closed (dropping all data).
  g_object_set(valve_, "drop", TRUE, nullptr);

  // H-5: bound the recording queue so the process cannot OOM if the encoder
  // stalls. Use time-based limiting (3 s) plus a 256 MB hard cap.
  // leaky=no means backpressure propagates upstream rather than silently
  // dropping frames, preserving recording integrity.
  g_object_set(queue_,
               "max-size-buffers", (guint)0,
               "max-size-time",    kRecQueueMaxTimeNs,
               "max-size-bytes",   kRecQueueMaxBytes,
               "leaky",            (gint)0,  // GST_QUEUE_NO_LEAK
               nullptr);

  // Configure encoder settings based on type.
  if (encoder_name_ == "x264enc") {
    int x264_kbps = 4000;
    if (video_bitrate > 0) {
      x264_kbps = video_bitrate / 1000;
      if (x264_kbps <= 0) x264_kbps = 1;
    }
    g_object_set(encoder_, "tune", 4 /* zerolatency */, "speed-preset", 2
                 /* superfast */, "bitrate", x264_kbps, nullptr);
  } else if (encoder_name_ == "openh264enc") {
    int openh264_bps = video_bitrate > 0 ? video_bitrate : 4000000;
    g_object_set(encoder_, "bitrate", openh264_bps, nullptr);
  } else if (encoder_name_ == "vah264enc" || encoder_name_ == "vaapih264enc") {
    if (video_bitrate > 0) {
      g_object_set(encoder_, "bitrate", video_bitrate / 1000, nullptr);
    }
  }

  // Add all video elements to the pipeline.
  gst_bin_add_many(GST_BIN(pipeline_), queue_, valve_, videoconvert_,
                   encoder_, h264parse_, muxer_, filesink_, nullptr);

  // Link: queue → valve → videoconvert → encoder → h264parse → muxer → filesink
  if (!gst_element_link_many(queue_, valve_, videoconvert_, encoder_,
                             h264parse_, muxer_, filesink_, nullptr)) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link recording pipeline elements");
    return false;
  }

  // Link tee to the recording queue.
  GstPad* tee_pad = gst_element_request_pad_simple(tee_, "src_%u");
  GstPad* queue_pad = gst_element_get_static_pad(queue_, "sink");
  GstPadLinkReturn link_ret = gst_pad_link(tee_pad, queue_pad);
  gst_object_unref(queue_pad);
  gst_object_unref(tee_pad);

  if (link_ret != GST_PAD_LINK_OK) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link tee to recording branch");
    return false;
  }

  // Sync video element states with the pipeline.
  gst_element_sync_state_with_parent(queue_);
  gst_element_sync_state_with_parent(valve_);
  gst_element_sync_state_with_parent(videoconvert_);
  gst_element_sync_state_with_parent(encoder_);
  gst_element_sync_state_with_parent(h264parse_);
  gst_element_sync_state_with_parent(muxer_);
  gst_element_sync_state_with_parent(filesink_);

  // Set up audio branch if requested.
  if (enable_audio) {
    GError* audio_error = nullptr;
    if (SetupAudioBranch(audio_bitrate, &audio_error)) {
      has_audio_ = true;
    } else {
      // Audio setup failed, log warning but continue without audio.
      g_warning("Audio setup failed: %s. Recording without audio.",
                audio_error ? audio_error->message : "unknown error");
      if (audio_error) g_error_free(audio_error);
      has_audio_ = false;
    }
  }

  is_setup_ = true;
  return true;
}

bool RecordHandler::SetupAudioBranch(int audio_bitrate, GError** error) {
  audio_encoder_name_ = DetectAudioEncoder();
  if (audio_encoder_name_.empty()) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "No audio encoder available");
    return false;
  }

  audio_source_ = gst_element_factory_make("autoaudiosrc", "rec_audio_src");
  audio_convert_ = gst_element_factory_make("audioconvert", "rec_audio_conv");
  audio_resample_ =
      gst_element_factory_make("audioresample", "rec_audio_resample");
  audio_encoder_ = gst_element_factory_make(audio_encoder_name_.c_str(),
                                             "rec_audio_enc");
  audio_queue_ = gst_element_factory_make("queue", "rec_audio_queue");
  audio_valve_ = gst_element_factory_make("valve", "rec_audio_valve");

  if (!audio_source_ || !audio_convert_ || !audio_resample_ ||
      !audio_encoder_ || !audio_queue_ || !audio_valve_) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to create audio pipeline elements");
    return false;
  }

  // Start with audio valve closed.
  g_object_set(audio_valve_, "drop", TRUE, nullptr);

  if (audio_bitrate > 0) {
    g_object_set(audio_encoder_, "bitrate", audio_bitrate, nullptr);
  }

  // Add audio elements to pipeline.
  gst_bin_add_many(GST_BIN(pipeline_), audio_source_, audio_queue_,
                   audio_valve_, audio_convert_, audio_resample_,
                   audio_encoder_, nullptr);

  // Link: autoaudiosrc → queue → valve → audioconvert → audioresample →
  // encoder
  if (!gst_element_link_many(audio_source_, audio_queue_, audio_valve_,
                             audio_convert_, audio_resample_, audio_encoder_,
                             nullptr)) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link audio pipeline elements");
    return false;
  }

  // Link audio encoder to the muxer.
  GstPad* audio_src = gst_element_get_static_pad(audio_encoder_, "src");
  GstPad* mux_audio_sink =
      gst_element_request_pad_simple(muxer_, "audio_%u");
  if (!audio_src || !mux_audio_sink) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to get audio pads for muxer");
    if (audio_src) gst_object_unref(audio_src);
    if (mux_audio_sink) gst_object_unref(mux_audio_sink);
    return false;
  }

  GstPadLinkReturn ret = gst_pad_link(audio_src, mux_audio_sink);
  gst_object_unref(audio_src);
  gst_object_unref(mux_audio_sink);

  if (ret != GST_PAD_LINK_OK) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link audio encoder to muxer");
    return false;
  }

  // Sync audio element states.
  gst_element_sync_state_with_parent(audio_source_);
  gst_element_sync_state_with_parent(audio_queue_);
  gst_element_sync_state_with_parent(audio_valve_);
  gst_element_sync_state_with_parent(audio_convert_);
  gst_element_sync_state_with_parent(audio_resample_);
  gst_element_sync_state_with_parent(audio_encoder_);

  return true;
}

bool RecordHandler::StartRecording(const std::string& output_path,
                                   GError** error) {
  if (is_recording_) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Recording is already in progress");
    return false;
  }

  if (!is_setup_) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Recording pipeline not set up");
    return false;
  }

  output_path_ = output_path;

  // Reset the muxer and filesink states to accept new data.
  gst_element_set_state(muxer_, GST_STATE_NULL);
  gst_element_set_state(filesink_, GST_STATE_NULL);
  g_object_set(filesink_, "location", output_path.c_str(), nullptr);
  gst_element_sync_state_with_parent(muxer_);
  gst_element_sync_state_with_parent(filesink_);

  // Open the video valve to let data flow.
  g_object_set(valve_, "drop", FALSE, nullptr);

  // Open the audio valve if audio is enabled.
  if (has_audio_ && audio_valve_) {
    g_object_set(audio_valve_, "drop", FALSE, nullptr);
  }

  is_recording_ = true;
  return true;
}

struct StopRecordingData {
  RecordHandler* handler;
  FlMethodCall* method_call;
  std::string output_path;
  std::string container;
  std::string video_codec;
  std::string audio_codec;
};

GstPadProbeReturn RecordHandler::OnEosEvent(GstPad* pad,
                                            GstPadProbeInfo* info,
                                            gpointer user_data) {
  if (GST_EVENT_TYPE(GST_PAD_PROBE_INFO_EVENT(info)) != GST_EVENT_EOS) {
    return GST_PAD_PROBE_PASS;
  }

  StopRecordingData* data = static_cast<StopRecordingData*>(user_data);

  // Respond on the main thread.
  g_idle_add(
      [](gpointer user_data) -> gboolean {
        StopRecordingData* data = static_cast<StopRecordingData*>(user_data);

        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result, "path",
                                 fl_value_new_string(data->output_path.c_str()));
        fl_value_set_string_take(result, "container",
                                 fl_value_new_string(data->container.c_str()));
        fl_value_set_string_take(result, "videoCodec",
                                 fl_value_new_string(data->video_codec.c_str()));
        fl_value_set_string_take(result, "audioCodec",
                                 fl_value_new_string(data->audio_codec.c_str()));
        fl_method_call_respond_success(data->method_call, result, nullptr);
        g_object_unref(data->method_call);

        data->handler->is_recording_ = false;
        delete data;
        return G_SOURCE_REMOVE;
      },
      data);

  return GST_PAD_PROBE_REMOVE;
}

void RecordHandler::StopRecording(FlMethodCall* method_call) {
  if (!is_recording_) {
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(method_call, "not_recording",
                                 "No recording in progress", details, nullptr);
    return;
  }

  // Set up an EOS probe on the filesink's sink pad BEFORE sending EOS so we
  // don't miss the event.
  GstPad* filesink_pad = gst_element_get_static_pad(filesink_, "sink");

  StopRecordingData* data = new StopRecordingData();
  data->handler = this;
  data->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  data->output_path = output_path_;
  data->container = output_extension();
  data->video_codec = encoder_name_;
  data->audio_codec = has_audio_ ? audio_encoder_name_ : "";

  if (filesink_pad) {
    gst_pad_add_probe(filesink_pad, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM,
                      RecordHandler::OnEosEvent, data, nullptr);
    gst_object_unref(filesink_pad);
  }

  // M-5 FIX: Send EOS to the valve's sink pad (not the encoder's sink pad).
  // The GStreamer valve element passes events (including EOS) downstream even
  // when drop=TRUE. Sending EOS here propagates correctly through the full
  // chain: valve → videoconvert → encoder → muxer → filesink, giving each
  // element a chance to flush its internal state before the file is closed.
  //
  // Close the valve AFTER sending EOS so that EOS is ordered after any frames
  // still in-flight between the tee and the valve's input.
  GstPad* valve_sink = gst_element_get_static_pad(valve_, "sink");
  if (valve_sink) {
    gst_pad_send_event(valve_sink, gst_event_new_eos());
    gst_object_unref(valve_sink);
  }
  // Now close the valve to block any subsequent tee data from entering the
  // recording branch (the EOS already committed the end of the stream).
  g_object_set(valve_, "drop", TRUE, nullptr);

  // Audio branch: close the audio valve and send EOS to the audio encoder.
  if (has_audio_ && audio_encoder_) {
    if (audio_valve_) {
      g_object_set(audio_valve_, "drop", TRUE, nullptr);
    }
    GstPad* audio_enc_sink =
        gst_element_get_static_pad(audio_encoder_, "sink");
    if (audio_enc_sink) {
      gst_pad_send_event(audio_enc_sink, gst_event_new_eos());
      gst_object_unref(audio_enc_sink);
    }
  }

  // If we couldn't set up the probe, respond immediately.
  if (!filesink_pad) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "path",
                             fl_value_new_string(data->output_path.c_str()));
    fl_value_set_string_take(result, "container",
                             fl_value_new_string(data->container.c_str()));
    fl_value_set_string_take(result, "videoCodec",
                             fl_value_new_string(data->video_codec.c_str()));
    fl_value_set_string_take(result, "audioCodec",
                             fl_value_new_string(data->audio_codec.c_str()));
    fl_method_call_respond_success(method_call, result, nullptr);
    g_object_unref(data->method_call);
    delete data;
    is_recording_ = false;
  }
}
