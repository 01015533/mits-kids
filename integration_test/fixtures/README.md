# Native media test fixtures

The video fixture is the first 59 compressed frames of the Butterfly-209.mp4
example already supplied with the pinned Flutter video_player_android 2.12.2
package. That sample is Copyright 2013 The Flutter Authors; the derived fixture
is redistributed under the BSD-3-Clause terms in
[LICENSE-video-fixture](LICENSE-video-fixture). The audio fixture is a generated
440 Hz test tone encoded as AAC.
The fixtures are imported only by integration tests and are not Flutter assets
or part of a normal production app build. These are codec fixtures, not an
MP4-import feature.

Generated locally with GStreamer 1.28.6:

```sh
gst-launch-1.0 -q filesrc location=Butterfly-209.mp4 ! qtdemux name=d d.video_0 ! h264parse ! identity eos-after=60 ! mp4mux ! filesink location=video.mp4
gst-launch-1.0 -q audiotestsrc num-buffers=140 samplesperbuffer=1024 wave=sine freq=440 ! audio/x-raw,rate=48000,channels=1 ! audioconvert ! fdkaacenc bitrate=32000 ! aacparse ! mp4mux ! filesink location=audio.mp4
```

Each file is base64-encoded into media_fixture.dart. Tests prove native muxing,
codec initialization, playback position and seeking; a person still needs to
confirm audible sound and picture on the physical tablet.
