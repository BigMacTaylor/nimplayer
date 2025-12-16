# ========================================================================================
#
#                                   Nimplayer
#                          version 0.0.1 by Mac_Taylor
#
# ========================================================================================

# Dependencies
# sudo apt install gstreamer1.0-gtk3

import std/os
import nim2gtk/[gtk, gst, glib]
import nim2gtk/[gdk, gobject, gio]

type CustomData = ref object
  playbin: Element
  slider: Scale
  sinkWidgetVal: Value
  sliderSigID: culong
  state: State
  duration: int64
  playbackBtn: Button

# ----------------------------------------------------------------------------------------
#                                    Callbacks
# ----------------------------------------------------------------------------------------

proc onPlayback(btn: Button, data: CustomData) =
  if data.state == State.playing: # Pause
    discard gst.setState(data.playbin, gst.State.paused)
    let icon = newImageFromIconName("media-playback-start-symbolic", IconSize.smallToolbar.ord)
    btn.setImage(icon)
    echo "Player paused"
  else: # Play
    discard gst.setState(data.playbin, gst.State.playing)
    let icon = newImageFromIconName("media-playback-pause-symbolic", IconSize.smallToolbar.ord)
    btn.setImage(icon)
    echo "Now playing"

proc onPause(btn: Button, data: CustomData) =
  discard gst.setState(data.playbin, gst.State.paused)
  let icon = newImageFromIconName("media-playback-start-symbolic", IconSize.smallToolbar.ord)
  data.playbackBtn.setImage(icon)
  echo "Player paused"

proc onStop(btn: Button, data: CustomData) =
  discard gst.setState(data.playbin, gst.State.ready)
  let icon = newImageFromIconName("media-playback-start-symbolic", IconSize.smallToolbar.ord)
  data.playbackBtn.setImage(icon)
  echo "Player stopped"

proc onSlider(slider: Scale, data: CustomData) =
  let value: cdouble = getValue(cast[Range](data.slider))
  let seekPos: int64 = int64(value) * SECOND
  let flags = cast[SeekFlags](SeekFlags.flush.ord or SeekFlags.keyUnit.ord)
  discard seekSimple(data.playbin, Format.time, flags, seekPos)

proc closeEvent(window: ApplicationWindow, event: gdk.Event, data: CustomData): bool =
  discard gst.setState(data.playbin, gst.State.ready)
  close(window)

proc destroyNotify(data: pointer) {.cdecl.} =
  echo "destroyNotify"

proc onMessage(bus: Bus, msg: gst.Message, data: CustomData) =
  let typ = msg.getType()

  if typ == {gst.MessageFlag.error}:
    var err: ptr glib.Error
    var debug_info: string
    msg.parseError(err, debug_info)
    echo "Error received from element " & $msg.getType() & ": " & $err.message & "\n"
    stderr.write("Debugging information: " & debug_info & "\n")

    # Set the pipeline to READY (which stops playback)
    discard gst.setState(data.playbin, gst.State.ready)

  if typ == {gst.MessageFlag.eos}:
    stdout.write("End-Of-Stream reached.\n")
    discard gst.setState(data.playbin, gst.State.ready)




  if typ == {gst.MessageFlag.stateChanged}:
    #if msg[].impl[].src of "playbin":
     # echo "playon"

    if msg.src.name() != "playbin":
      return

    var old, new, pending: State
    msg.parseStateChanged(old, new, pending)
    data.state = new

    echo "Object kind:", typ, " name:", msg.src.name()

    var srcElement = msg[].impl[].src
    let eName = gst_object_get_name(srcElement)
    if srcElement.isNil:
      return

    #let eName = getName(srcElement)
    echo eName

    #let src = cast[Source](msg.impl.src)
    #let srcName = src.getName()
    #echo srcName


# ----------------------------------------------------------------------------------------
#                                    Refresh GUI
# ----------------------------------------------------------------------------------------

proc refreshUI(data: CustomData): gboolean {.cdecl.} =
  if data.state.ord < gst.State.paused.ord:
    return gboolean(1)

  assert not data.playbin.isNil, "Error, no playback element"

  var pos: int64 = -1
  var adj = getAdjustment(data.slider)

  # If we didn't know it yet, query the stream duration
  if data.duration == -1:
    if queryDuration(data.playbin, Format.time, data.duration):
      # Set the range of the slider to the clip duration, in SECONDS
      adj.setUpper(cdouble(data.duration div SECOND))
      #setRange(cast [Range](data.slider), cdouble(0), cdouble(cast[var int64](data.duration) div SECOND));
    else:
      echo "Could not query current duration.\n"

  if queryPosition(data.playbin, Format.time, pos):
    signalHandlerBlock(data.slider, data.sliderSigID)
    adj.setValue(cdouble(pos div SECOND))
    signalHandlerUnblock(data.slider, data.sliderSigID)

  return gboolean(1)

# ----------------------------------------------------------------------------------------
#                                    Window
# ----------------------------------------------------------------------------------------

proc createUI(app: Application, data: CustomData) =
  let window = newApplicationWindow(app)
  window.title = "nimplayer"
  window.defaultSize = (640, 480)
  window.connect("delete-event", closeEvent, data)

  let mainBox = newBox(Orientation.vertical)

  data.playbackBtn =
    gtk.newButtonFromIconName("media-playback-start-symbolic", IconSize.smallToolbar.ord)
  data.playbackBtn.connect("clicked", onPlayback, data)
  let stopBtn =
    gtk.newButtonFromIconName("media-playback-stop-symbolic", IconSize.smallToolbar.ord)
  stopBtn.connect("clicked", onStop, data)

  data.slider = newScaleWithRange(Orientation.horizontal, 0, 100, 1)
  setDrawValue(data.slider, false)
  data.sliderSigID = data.slider.connect("value-changed", onSlider, data)

  let controlBox = newBox(Orientation.horizontal)
  controlBox.packStart(data.playbackBtn,  false, false, 2)
  controlBox.packStart(stopBtn,  false, false, 2)
  controlBox.packStart(data.slider, true,  true,  2)

  let widgetObj = getObject(data.sinkWidgetVal)
  let sinkWidget: Widget = cast[Widget](widgetObj)

  let videoBox = newBox(Orientation.horizontal)
  videoBox.packStart(sinkWidget, true, true, 0)

  # Pack mainBox,   (Widget;   expand; fill; padding)
  mainBox.packStart(videoBox,   true,  true,    0)
  mainBox.packStart(controlBox, false, false,   0)

  window.add(mainBox)
  window.showAll()

# ----------------------------------------------------------------------------------------
#                                    Application
# ----------------------------------------------------------------------------------------

proc appActivate(app: Application) =
  var data = new(CustomData)
  var ret: StateChangeReturn
  var bus: Bus
  var gtkglsink, videosink: Element
  var pending: State

  # Initialize GStreamer
  gst.init()

  # Initialize data
  data.duration = -1

  # Create the elements
  data.playbin = make("playbin", "playbin")
  videosink = make("glsinkbin", "glsinkbin")
  gtkglsink = make("gtkglsink", "gtkglsink")

  # Here we create the GTK Sink element which will provide us with a GTK widget where
  # GStreamer will render the video at and we can add to our UI.
  # Try to create the OpenGL version of the video sink, and fallback if that fails
  if not videosink.isNil and not gtkglsink.isNil:
    echo "Successfully created GTK GL Sink"
    videosink.setProperty("sink", newValue(gtkglsink))

    # The gtkglsink creates the gtk widget for us. This is accessible through
    # a property. So we get it and use it later in our gui.
    gtkglsink.getProperty("widget", data.sinkWidgetVal)
  else:
    echo "Could not create gtkglsink, falling back to gtksink.\n"
    videosink = make("gtksink", "gtksink")
    videosink.getProperty("widget", data.sinkWidgetVal)

  assert not data.playbin.isNil and not videosink.isNil, "Could not create all elements"

  # Set the URI to play
  let uriVal =
    newValue("https://gstreamer.freedesktop.org/media/sintel_trailer-480p.webm")
  data.playbin.setProperty("uri", uriVal)

  # Set the video-sink
  data.playbin.setProperty("video-sink", newValue(videosink))

  # Create the GUI
  app.createUI(data)

  # Instruct the bus to emit signals for each received message
  bus = gst.getBus(data.playbin)
  bus.addSignalWatch()
  bus.connect("message", onMessage, data)

  # Start playing
  ret = gst.setState(data.playbin, gst.State.playing)
  let icon = newImageFromIconName("media-playback-pause-symbolic", IconSize.smallToolbar.ord)
  data.playbackBtn.setImage(icon)

  if ret == failure:
    echo "Unable to set the pipeline to the playing state.\n"
    data.playbin.unref()
    videosink.unref()
    return

  ret = gst.getState(data.playbin, data.state, pending, CLOCK_TIME_NONE)

  if ret == success:
    echo "Pipeline is now in the " & stateGetName(data.state) & " state"

  # Register a function that GLib will call every second
  discard timeoutAddSeconds(
    0, 1, cast[SourceFunc](refreshUI), cast[pointer](data), destroyNotify
  )

# ----------------------------------------------------------------------------------------
#                                    Main
# ----------------------------------------------------------------------------------------

proc main() =
  let app = newApplication("org.gtk.nimplayer")

  connect(app, "activate", appActivate)
  discard app.run()

when isMainModule:
  main()
