#ifndef RECORD_HANDLER_H_
#define RECORD_HANDLER_H_

#include <gst/gst.h>
#include <flutter_linux/flutter_linux.h>

#include <string>

// Manages a video recording branch using a tee + valve + encoder + mux pipeline.
//
// Video pipeline:
//   tee → queue → valve → videoconvert → encoder → h264parse → mux → filesink
//
// Audio pipeline (optional, when enable_audio is true):
//   autoaudiosrc → audioconvert → audioresample → opusenc → mux
//
// The valve starts closed (drop=true). When recording starts, the valve opens
// and frames flow through to the encoder. When recording stops, the valve
// closes and an EOS event is sent downstream to finalize the file.
class RecordHandler {
 public:
  RecordHandler();
  ~RecordHandler();

  // Detects the best available H.264 encoder at runtime.
  // Returns the GStreamer element factory name, or empty string if none found.
  static std::string DetectEncoder();

  // Detects the best available audio encoder at runtime.
  static std::string DetectAudioEncoder();

  // Sets up the recording branch and attaches it to the tee element.
  // |tee| is the pipeline tee element to branch from.
  // |width| and |height| are the video dimensions.
  // |fps| is the target frame rate.
  // |enable_audio| adds an audio source and encoder to the recording.
  // Returns true on success; sets |error| on failure.
  bool Setup(GstElement* pipeline, GstElement* tee,
             int width, int height, int fps, int video_bitrate,
             int audio_bitrate, bool enable_audio, GError** error);

  // Starts recording to the given file path.
  // Returns true on success; sets |error| on failure.
  bool StartRecording(const std::string& output_path, GError** error);

  // Stops recording. Sends EOS through the recording branch and waits
  // for the file to be finalized. |method_call| is responded to
  // asynchronously when the file is ready (or an error occurs).
  void StopRecording(FlMethodCall* method_call);

  bool is_recording() const { return is_recording_; }
  bool has_audio() const { return has_audio_; }
  const std::string& encoder_name() const { return encoder_name_; }
  const std::string& audio_encoder_name() const { return audio_encoder_name_; }

  // H-6: returns the correct file extension for the muxer that was selected.
  // "mp4" if mp4mux is available, "mkv" if matroskamux was the fallback.
  const char* output_extension() const {
    return using_matroskamux_ ? "mkv" : "mp4";
  }

 private:
  static GstPadProbeReturn OnEosEvent(GstPad* pad, GstPadProbeInfo* info,
                                      gpointer user_data);

  bool SetupAudioBranch(int audio_bitrate, GError** error);

  GstElement* pipeline_;     // Not owned.
  GstElement* tee_;          // Not owned.
  GstElement* queue_;        // Owned by pipeline.
  GstElement* valve_;        // Owned by pipeline.
  GstElement* videoconvert_; // Owned by pipeline.
  GstElement* encoder_;      // Owned by pipeline.
  GstElement* h264parse_;    // Owned by pipeline.
  GstElement* muxer_;        // Owned by pipeline.
  GstElement* filesink_;     // Owned by pipeline.

  // Audio elements (optional).
  GstElement* audio_source_;    // Owned by pipeline.
  GstElement* audio_convert_;   // Owned by pipeline.
  GstElement* audio_resample_;  // Owned by pipeline.
  GstElement* audio_encoder_;   // Owned by pipeline.
  GstElement* audio_queue_;     // Owned by pipeline.
  GstElement* audio_valve_;     // Owned by pipeline.

  std::string encoder_name_;
  std::string audio_encoder_name_;
  std::string output_path_;
  bool is_recording_;
  bool is_setup_;
  bool has_audio_;
  bool using_matroskamux_ = false;  // H-6: true when mp4mux was unavailable

  FlMethodCall* pending_stop_call_;  // Pending stop response.
};

#endif  // RECORD_HANDLER_H_
