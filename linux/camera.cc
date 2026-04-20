#include "camera.h"
#include "photo_handler.h"

#include <gio/gio.h>
#include <gst/video/video.h>

#include <atomic>
#include <cstdio>
#include <cstring>

static const guint kInitTimeoutMs = 8000;

Camera::Camera(int camera_id,
               FlTextureRegistrar* texture_registrar,
               FlMethodChannel* method_channel,
               const CameraConfig& config)
    : camera_id_(camera_id),
      texture_id_(-1),
      state_(CameraState::kCreated),
      config_(config),
      texture_registrar_(texture_registrar),
      method_channel_(method_channel),
      texture_(nullptr),
      pipeline_(nullptr),
      tee_(nullptr),
      appsink_(nullptr),
      videoflip_(nullptr),
      bus_watch_id_(0),
      init_timeout_id_(0),
      record_handler_(std::make_unique<RecordHandler>()),
      pending_init_call_(nullptr),
      first_frame_received_(false),
      preview_paused_(false),
      image_streaming_(false),
      image_stream_callback_(nullptr),
      actual_width_(0),
      actual_height_(0) {}

Camera::~Camera() {
  Dispose();
}

int64_t Camera::RegisterTexture() {
  texture_ = camera_texture_new();
  FlTexture* fl_tex = camera_texture_as_fl_texture(texture_);
  if (!fl_texture_registrar_register_texture(texture_registrar_, fl_tex)) {
    g_info("[camera_desktop] Camera %d: failed to register Flutter texture",
           camera_id_);
    g_object_unref(texture_);
    texture_ = nullptr;
    return -1;
  }
  texture_id_ = fl_texture_get_id(fl_tex);
  return texture_id_;
}

void Camera::Initialize(FlMethodCall* method_call) {
  if (state_.load() != CameraState::kCreated) {
    g_info("[camera_desktop] Camera %d: Initialize called in unexpected state %d",
           camera_id_, static_cast<int>(state_.load()));
    g_autoptr(FlValue) error_details = fl_value_new_null();
    fl_method_call_respond_error(method_call, "already_initialized",
                                 "Camera is already initialized or disposed",
                                 error_details, nullptr);
    return;
  }

  state_.store(CameraState::kInitializing);
  pending_init_call_ = FL_METHOD_CALL(g_object_ref(method_call));
  first_frame_received_.store(false);

  g_info("[camera_desktop] Initializing camera %d (%s backend, %dx%d@%dfps)",
         camera_id_,
         config_.backend == CameraBackend::kPipeWire ? "PipeWire" : "V4L2",
         config_.target_width, config_.target_height, config_.target_fps);

  GError* error = nullptr;
  if (!BuildPipeline(&error)) {
    g_info("[camera_desktop] Camera %d: BuildPipeline failed: %s", camera_id_,
           error ? error->message : "unknown error");
    RespondToPendingInit(false, error->message);
    g_error_free(error);
    state_.store(CameraState::kCreated);
    return;
  }

  // Set pipeline to PLAYING.
  GstStateChangeReturn ret =
      gst_element_set_state(pipeline_, GST_STATE_PLAYING);
  if (ret == GST_STATE_CHANGE_FAILURE) {
    g_info("[camera_desktop] Camera %d: gst_element_set_state(PLAYING) failed",
           camera_id_);
    RespondToPendingInit(false, "Failed to start GStreamer pipeline");
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
    appsink_ = nullptr;
    state_.store(CameraState::kCreated);
    return;
  }

  // Set a timeout for initialization, if no frame arrives in time, fail.
  init_timeout_id_ =
      g_timeout_add(kInitTimeoutMs, Camera::OnInitTimeout, this);
}

bool Camera::BuildPipeline(GError** error) {
  // Build pipeline with a tee to support branching for recording:
  //   [source] ! videoconvert ! caps ! tee name=t
  //     t. ! queue ! appsink (preview)
  //     t. ! [recording branch, added later by RecordHandler]
  gchar* pipeline_str = nullptr;

  if (config_.backend == CameraBackend::kPipeWire) {
    // PipeWire portal path: use pipewiresrc with the portal-provided fd.
    // Extract node id from "pw:<id>" device_path.
    std::string pw_node_id = config_.device_path.substr(3);
    pipeline_str = g_strdup_printf(
        "pipewiresrc fd=%d path=%s do-timestamp=true "
        "! videoconvert "
        "! videoflip name=flip method=horizontal-flip "
        "! video/x-raw,format=RGBA,width=%d,height=%d,framerate=%d/1 "
        "! tee name=t "
        "t. ! queue name=preview_queue ! "
        "appsink name=sink emit-signals=true max-buffers=2 drop=true "
        "sync=false",
        config_.pw_fd, pw_node_id.c_str(),
        config_.target_width, config_.target_height, config_.target_fps);
  } else {
    // V4L2 path (default for native Linux installs).
    pipeline_str = g_strdup_printf(
        "v4l2src device=%s "
        "! videoconvert "
        "! videoflip name=flip method=horizontal-flip "
        "! video/x-raw,format=RGBA,width=%d,height=%d,framerate=%d/1 "
        "! tee name=t "
        "t. ! queue name=preview_queue ! "
        "appsink name=sink emit-signals=true max-buffers=2 drop=true "
        "sync=false",
        config_.device_path.c_str(), config_.target_width,
        config_.target_height, config_.target_fps);
  }

  g_info("[camera_desktop] Pipeline: %s", pipeline_str);
  pipeline_ = gst_parse_launch(pipeline_str, error);
  g_free(pipeline_str);

  if (!pipeline_) {
    return false;
  }

  // Get the tee element (needed for recording branch attachment).
  tee_ = gst_bin_get_by_name(GST_BIN(pipeline_), "t");
  if (!tee_) {
    g_info("[camera_desktop] Camera %d: tee element not found in pipeline",
           camera_id_);
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to find tee in pipeline");
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
    return false;
  }
  // Release our ref (pipeline holds one).
  gst_object_unref(tee_);

  // Get the videoflip element for runtime mirror toggling.
  videoflip_ = gst_bin_get_by_name(GST_BIN(pipeline_), "flip");
  if (videoflip_) {
    gst_object_unref(videoflip_);  // Pipeline holds the ref.
  } else {
    g_info("[camera_desktop] Camera %d: videoflip element not found in pipeline"
           " (mirror toggling will be unavailable)", camera_id_);
  }

  // Get the appsink element.
  appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "sink");
  if (!appsink_) {
    g_info("[camera_desktop] Camera %d: appsink element not found in pipeline",
           camera_id_);
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to find appsink in pipeline");
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
    return false;
  }

  // Connect the new-sample signal.
  GstAppSinkCallbacks callbacks = {};
  callbacks.new_sample = Camera::OnNewSample;
  gst_app_sink_set_callbacks(GST_APP_SINK(appsink_), &callbacks, this,
                             nullptr);

  // Set up bus watch for error messages.
  GstBus* bus = gst_pipeline_get_bus(GST_PIPELINE(pipeline_));
  bus_watch_id_ = gst_bus_add_watch(bus, Camera::OnBusMessage, this);
  gst_object_unref(bus);

  // Release our ref on the appsink (pipeline holds one).
  gst_object_unref(appsink_);

  return true;
}

void Camera::RespondToPendingInit(bool success, const char* error_message) {
  if (!pending_init_call_) return;

  // Cancel the timeout.
  if (init_timeout_id_ > 0) {
    g_source_remove(init_timeout_id_);
    init_timeout_id_ = 0;
  }

  if (success) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "previewWidth",
                             fl_value_new_float((double)actual_width_.load()));
    fl_value_set_string_take(result, "previewHeight",
                             fl_value_new_float((double)actual_height_.load()));
    fl_method_call_respond_success(pending_init_call_, result, nullptr);
  } else {
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(pending_init_call_, "initialization_failed",
                                 error_message ? error_message : "Unknown error",
                                 details, nullptr);
  }

  g_object_unref(pending_init_call_);
  pending_init_call_ = nullptr;
}

GstFlowReturn Camera::OnNewSample(GstAppSink* sink, gpointer user_data) {
  Camera* self = static_cast<Camera*>(user_data);

  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (!sample) {
    g_warning("[camera_desktop] OnNewSample: gst_app_sink_pull_sample returned null");
    return GST_FLOW_ERROR;
  }

  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstCaps* caps = gst_sample_get_caps(sample);

  GstVideoInfo info;
  if (!gst_video_info_from_caps(&info, caps)) {
    g_warning("[camera_desktop] OnNewSample: gst_video_info_from_caps failed");
    gst_sample_unref(sample);
    return GST_FLOW_ERROR;
  }

  int width = GST_VIDEO_INFO_WIDTH(&info);
  int height = GST_VIDEO_INFO_HEIGHT(&info);
  int stride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);

  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    g_warning("[camera_desktop] OnNewSample: gst_buffer_map failed");
    gst_sample_unref(sample);
    return GST_FLOW_ERROR;
  }

  // Handle first-frame initialization response.
  // C-2: first_frame_received_ is atomic, safe cross-thread read/write.
  bool is_first_frame = !self->first_frame_received_.load();
  if (is_first_frame) {
    g_info("[camera_desktop] Camera %d: first frame received (%dx%d)",
           self->camera_id_, width, height);
    self->first_frame_received_.store(true);
    // H-2: actual_width_/height_ are atomic, safe cross-thread write.
    self->actual_width_.store(width);
    self->actual_height_.store(height);
    self->state_.store(CameraState::kRunning);
  }

  // Update the texture only if preview is not paused (or if this is the first
  // frame, which we need for initialization).
  // C-3: preview_paused_ is atomic, safe cross-thread read.
  if (!self->preview_paused_.load() || is_first_frame) {
    if (stride == width * 4) {
      // No padding, direct copy.
      camera_texture_update(self->texture_, map.data, width, height);
    } else {
      // Stride has padding, copy row-by-row into a tight buffer.
      // M-1 note: this intermediate allocation is unavoidable here since
      // camera_texture_update requires a tightly-packed buffer.
      size_t tight_size = (size_t)width * height * 4;
      uint8_t* tight = (uint8_t*)g_malloc(tight_size);
      for (int row = 0; row < height; row++) {
        memcpy(tight + row * width * 4, map.data + row * stride, width * 4);
      }
      camera_texture_update(self->texture_, tight, width, height);
      g_free(tight);
    }

    // Notify Flutter that a new frame is available.
    fl_texture_registrar_mark_texture_frame_available(
        self->texture_registrar_,
        camera_texture_as_fl_texture(self->texture_));
  }

  // Send frame to Dart image stream if streaming is active.
  if (self->image_streaming_.load()) {
    // C-4: load the callback pointer atomically once, then use the local copy.
    // This prevents a TOCTOU race where the pointer is nulled between the
    // check and the call.
    ImageStreamCallback cb = self->image_stream_callback_.load();
    if (cb) {
      // FFI path: write to shared buffer, notify Dart directly.
      size_t frame_size = (size_t)width * height * 4;
      size_t total_size = offsetof(Camera::ImageStreamBuffer, pixels) + frame_size;

      if (self->image_stream_buffer_size_ < total_size) {
        g_free(self->image_stream_buffer_);
        self->image_stream_buffer_ =
            (Camera::ImageStreamBuffer*)g_malloc(total_size);
        self->image_stream_buffer_size_ = total_size;
      }

      auto* buf = self->image_stream_buffer_;
      buf->ready = 0;

      if (stride == width * 4) {
        memcpy(buf->pixels, map.data, frame_size);
      } else {
        for (int row = 0; row < height; row++) {
          memcpy(buf->pixels + row * width * 4, map.data + row * stride,
                 width * 4);
        }
      }

      buf->width = width;
      buf->height = height;
      buf->bytes_per_row = width * 4;
      buf->format = 1;  // RGBA (Linux GStreamer pipeline)
      buf->sequence = ++self->image_stream_sequence_;

      // C-5: release fence, guarantees all pixel and metadata writes above
      // are visible to any thread that subsequently observes ready == 1.
      std::atomic_thread_fence(std::memory_order_release);
      buf->ready = 1;

      cb(self->camera_id_);
    } else {
      // Legacy MethodChannel fallback path.
      size_t frame_size = (size_t)width * height * 4;
      uint8_t* frame_copy = (uint8_t*)g_malloc(frame_size);
      if (stride == width * 4) {
        memcpy(frame_copy, map.data, frame_size);
      } else {
        for (int row = 0; row < height; row++) {
          memcpy(frame_copy + row * width * 4, map.data + row * stride,
                 width * 4);
        }
      }

      struct ImageStreamData {
        FlMethodChannel* channel;
        int camera_id;
        uint8_t* pixels;
        int width;
        int height;
        size_t size;
      };

      auto* stream_data = new ImageStreamData();
      stream_data->channel = self->method_channel_;
      stream_data->camera_id = self->camera_id_;
      stream_data->pixels = frame_copy;
      stream_data->width = width;
      stream_data->height = height;
      stream_data->size = frame_size;

      g_idle_add(
          [](gpointer user_data) -> gboolean {
            auto* data = static_cast<ImageStreamData*>(user_data);

            g_autoptr(FlValue) args = fl_value_new_map();
            fl_value_set_string_take(args, "cameraId",
                                     fl_value_new_int(data->camera_id));
            fl_value_set_string_take(args, "width",
                                     fl_value_new_int(data->width));
            fl_value_set_string_take(args, "height",
                                     fl_value_new_int(data->height));
            fl_value_set_string_take(
                args, "bytes",
                fl_value_new_uint8_list(data->pixels, data->size));

            fl_method_channel_invoke_method(data->channel, "imageStreamFrame",
                                            args, nullptr, nullptr, nullptr);

            g_free(data->pixels);
            delete data;
            return G_SOURCE_REMOVE;
          },
          stream_data);
    }
  }

  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);

  // Dispatch init response to the main thread (OnNewSample runs on the
  // GStreamer streaming thread, but fl_method_call_respond_* must be called
  // from the main GLib thread).
  if (is_first_frame) {
    g_idle_add(
        [](gpointer user_data) -> gboolean {
          Camera* cam = static_cast<Camera*>(user_data);
          cam->RespondToPendingInit(true, nullptr);
          return G_SOURCE_REMOVE;
        },
        self);
  }

  return GST_FLOW_OK;
}

gboolean Camera::OnBusMessage(GstBus* bus, GstMessage* msg,
                              gpointer user_data) {
  Camera* self = static_cast<Camera*>(user_data);

  switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
      GError* err = nullptr;
      gchar* debug = nullptr;
      gst_message_parse_error(msg, &err, &debug);

      g_info("[camera_desktop] Camera %d: GStreamer error: %s (debug: %s)",
             self->camera_id_,
             err ? err->message : "unknown",
             debug ? debug : "none");

      // C-2: load state_ atomically.
      CameraState s = self->state_.load();
      if (s == CameraState::kInitializing) {
        self->RespondToPendingInit(false, err->message);
        self->state_.store(CameraState::kCreated);
      } else if (s == CameraState::kRunning || s == CameraState::kPaused) {
        self->SendError(err->message);
      }

      g_error_free(err);
      g_free(debug);
      break;
    }
    case GST_MESSAGE_EOS: {
      // End of stream (e.g., device unplugged).
      CameraState s = self->state_.load();
      if (s == CameraState::kRunning || s == CameraState::kPaused) {
        self->SendError("Camera stream ended unexpectedly");
      }
      break;
    }
    default:
      break;
  }
  return TRUE;
}

gboolean Camera::OnInitTimeout(gpointer user_data) {
  Camera* self = static_cast<Camera*>(user_data);
  self->init_timeout_id_ = 0;

  if (self->state_.load() == CameraState::kInitializing) {
    self->RespondToPendingInit(
        false, "Camera initialization timed out, no frames received");
    if (self->pipeline_) {
      gst_element_set_state(self->pipeline_, GST_STATE_NULL);
    }
    self->state_.store(CameraState::kCreated);
  }
  return G_SOURCE_REMOVE;
}

void Camera::SendError(const std::string& description) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "cameraId",
                           fl_value_new_int(camera_id_));
  fl_value_set_string_take(args, "description",
                           fl_value_new_string(description.c_str()));
  fl_method_channel_invoke_method(method_channel_, "cameraError", args,
                                  nullptr, nullptr, nullptr);
}

void Camera::TakePicture(FlMethodCall* method_call) {
  CameraState s = state_.load();
  if (s != CameraState::kRunning && s != CameraState::kPaused) {
    g_info("[camera_desktop] Camera %d: TakePicture called but camera is not"
           " running (state=%d)", camera_id_, static_cast<int>(s));
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(method_call, "not_running",
                                 "Camera is not running", details, nullptr);
    return;
  }

  // Generate a unique temporary file path using an atomic sequence counter
  // rather than the wall clock to prevent collisions under NTP corrections.
  static std::atomic<int64_t> capture_seq{0};
  gchar* tmp_path =
      g_strdup_printf("%s/camera_desktop_%d_%" G_GINT64_FORMAT ".jpg",
                      g_get_tmp_dir(), camera_id_,
                      capture_seq.fetch_add(1, std::memory_order_relaxed));

  // C-7: gst_video_convert_sample performs synchronous JPEG encoding which
  // can take 30–200 ms at 1080p. Offload to a GLib thread-pool task so the
  // main/UI thread is never blocked.
  //
  // Take a GStreamer reference to appsink_ so it stays alive for the duration
  // of the task even if Dispose() is called concurrently.
  struct TakePictureData {
    GstElement* appsink;   // holds a gst_object_ref
    std::string output_path;
    std::string error_message;
    bool success;
    FlMethodCall* method_call;  // holds a g_object_ref
  };

  auto* d = new TakePictureData();
  d->appsink = GST_ELEMENT(gst_object_ref(appsink_));
  d->output_path = tmp_path;
  d->success = false;
  d->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  g_free(tmp_path);

  GTask* task = g_task_new(nullptr, nullptr, nullptr, nullptr);
  g_task_set_task_data(task, d, nullptr);
  g_task_run_in_thread(
      task,
      [](GTask* /*task*/, gpointer /*source*/, gpointer task_data,
         GCancellable* /*cancel*/) {
        auto* d = static_cast<TakePictureData*>(task_data);
        GError* err = nullptr;
        d->success = PhotoHandler::TakePicture(d->appsink, d->output_path, &err);
        gst_object_unref(d->appsink);
        d->appsink = nullptr;
        if (!d->success && err) {
          d->error_message = err->message;
          g_error_free(err);
        }
        // Marshal the method-channel response back to the main GLib thread.
        g_idle_add(
            [](gpointer p) -> gboolean {
              auto* d = static_cast<TakePictureData*>(p);
              if (d->success) {
                g_autoptr(FlValue) result =
                    fl_value_new_string(d->output_path.c_str());
                fl_method_call_respond_success(d->method_call, result, nullptr);
              } else {
                g_autoptr(FlValue) details = fl_value_new_null();
                fl_method_call_respond_error(
                    d->method_call, "capture_failed",
                    d->error_message.empty() ? "Failed to capture image"
                                             : d->error_message.c_str(),
                    details, nullptr);
              }
              g_object_unref(d->method_call);
              delete d;
              return G_SOURCE_REMOVE;
            },
            d);
      });
  g_object_unref(task);
}

void Camera::StartVideoRecording(FlMethodCall* method_call) {
  CameraState s = state_.load();
  if (s != CameraState::kRunning && s != CameraState::kPaused) {
    g_info("[camera_desktop] Camera %d: StartVideoRecording called but camera"
           " is not running (state=%d)", camera_id_, static_cast<int>(s));
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(method_call, "not_running",
                                 "Camera is not running", details, nullptr);
    return;
  }

  // Set up the recording branch on first use.
  if (!record_handler_->is_recording()) {
    GError* error = nullptr;
    // H-2: load actual dimensions atomically, they are written from the
    // GStreamer streaming thread on first frame.
    if (!record_handler_->Setup(pipeline_, tee_,
                                actual_width_.load(), actual_height_.load(),
                                config_.target_fps,
                                config_.target_bitrate,
                                config_.audio_bitrate,
                                config_.enable_audio, &error)) {
      g_info("[camera_desktop] Camera %d: RecordHandler::Setup failed: %s",
             camera_id_, error ? error->message : "unknown error");
      g_autoptr(FlValue) details = fl_value_new_null();
      fl_method_call_respond_error(
          method_call, "recording_setup_failed",
          error ? error->message : "Failed to set up recording", details,
          nullptr);
      if (error) g_error_free(error);
      return;
    }
    if (config_.enable_audio && !record_handler_->has_audio()) {
      SendError("Audio recording was requested but audio setup failed. "
                "Recording will continue without audio.");
    }
  }

  // H-6: derive extension from the muxer that was actually selected so the
  // file's extension always matches its container format.
  static std::atomic<int64_t> rec_seq{0};
  gchar* tmp_path = g_strdup_printf(
      "%s/camera_desktop_%d_%" G_GINT64_FORMAT ".%s",
      g_get_tmp_dir(), camera_id_,
      rec_seq.fetch_add(1, std::memory_order_relaxed),
      record_handler_->output_extension());

  GError* error = nullptr;
  if (!record_handler_->StartRecording(tmp_path, &error)) {
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(
        method_call, "recording_start_failed",
        error ? error->message : "Failed to start recording", details,
        nullptr);
    if (error) g_error_free(error);
    g_free(tmp_path);
    return;
  }

  g_free(tmp_path);
  fl_method_call_respond_success(method_call, fl_value_new_null(), nullptr);
}

void Camera::StopVideoRecording(FlMethodCall* method_call) {
  if (!record_handler_->is_recording()) {
    g_info("[camera_desktop] Camera %d: StopVideoRecording called but not"
           " recording", camera_id_);
    g_autoptr(FlValue) details = fl_value_new_null();
    fl_method_call_respond_error(method_call, "not_recording",
                                 "No recording in progress", details, nullptr);
    return;
  }

  record_handler_->StopRecording(method_call);
}

void Camera::StartImageStream() {
  g_info("[camera_desktop] Camera %d: starting image stream", camera_id_);
  image_streaming_ = true;
}

void Camera::StopImageStream() {
  g_info("[camera_desktop] Camera %d: stopping image stream", camera_id_);
  image_streaming_ = false;
}

void Camera::RegisterImageStreamCallback(void (*callback)(int32_t)) {
  // C-4: atomic store, safe to write from main thread while GStreamer thread
  // reads. The GStreamer thread loads the pointer once per frame (see
  // OnNewSample) so it cannot race between check and call.
  image_stream_callback_.store(callback);
}

void Camera::UnregisterImageStreamCallback() {
  image_stream_callback_.store(nullptr);
}

void Camera::PausePreview() {
  g_info("[camera_desktop] Camera %d: pausing preview", camera_id_);
  // C-3: atomic store, safe cross-thread write.
  preview_paused_.store(true);
}

void Camera::ResumePreview() {
  g_info("[camera_desktop] Camera %d: resuming preview", camera_id_);
  preview_paused_.store(false);
}

void Camera::SetMirror(bool mirrored) {
  if (!videoflip_) {
    g_info("[camera_desktop] Camera %d: SetMirror(%s) ignored, videoflip_ is null",
           camera_id_, mirrored ? "true" : "false");
    return;
  }
  g_info("[camera_desktop] Camera %d: SetMirror(%s)", camera_id_,
         mirrored ? "true" : "false");
  // GstVideoFlipMethod: 0 = none (identity), 4 = horizontal-flip
  g_object_set(videoflip_, "method", mirrored ? 4 : 0, nullptr);
}

void Camera::Dispose() {
  g_info("[camera_desktop] Camera %d: disposing", camera_id_);
  // C-2: use atomic exchange so the check-and-set is race-free. If two threads
  // somehow call Dispose() concurrently, only one proceeds.
  CameraState prev = state_.exchange(CameraState::kDisposing);
  if (prev == CameraState::kDisposed || prev == CameraState::kDisposing) {
    return;
  }

  // Cancel pending init if still waiting (main thread → main thread, safe).
  if (pending_init_call_) {
    RespondToPendingInit(false, "Camera disposed during initialization");
  }

  // C-4: null the callback atomically BEFORE stopping the pipeline. This
  // prevents new FFI callbacks from being registered while we're tearing down,
  // but does NOT free the buffer yet, that must wait until the pipeline stops.
  image_stream_callback_.store(nullptr);

  // C-1 FIX: stop the pipeline BEFORE freeing image_stream_buffer_.
  // gst_element_set_state(NULL) blocks until the GStreamer streaming thread
  // (which runs OnNewSample and accesses image_stream_buffer_) is fully
  // stopped. Freeing before this point was a use-after-free.
  if (pipeline_) {
    videoflip_ = nullptr;
    gst_element_set_state(pipeline_, GST_STATE_NULL);
    if (bus_watch_id_ > 0) {
      g_source_remove(bus_watch_id_);
      bus_watch_id_ = 0;
    }
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
    appsink_ = nullptr;
  }

  // Now safe: the GStreamer streaming thread is guaranteed to have exited
  // OnNewSample and will never access image_stream_buffer_ again.
  if (image_stream_buffer_) {
    g_free(image_stream_buffer_);
    image_stream_buffer_ = nullptr;
    image_stream_buffer_size_ = 0;
  }

  // Unregister the texture.
  if (texture_ && texture_registrar_) {
    fl_texture_registrar_unregister_texture(
        texture_registrar_, camera_texture_as_fl_texture(texture_));
    g_object_unref(texture_);
    texture_ = nullptr;
  }

  // Send closing event to Dart.
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "cameraId",
                           fl_value_new_int(camera_id_));
  fl_method_channel_invoke_method(method_channel_, "cameraClosing", args,
                                  nullptr, nullptr, nullptr);

  state_.store(CameraState::kDisposed);
  g_info("[camera_desktop] Camera %d: disposed", camera_id_);
}
