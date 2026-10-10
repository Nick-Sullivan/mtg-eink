/// Drive Waveshare's passive NFC-powered e-Paper panels from Android.
///
/// Hand it a packed frame and it puts it on the panel; what the frame shows is the caller's
/// business. In outline:
///
/// - [PanelDevice] describes each supported panel — geometry, inks, how a frame is laid out — and
///   [PanelDevice.forAts] tells which one is on the phone from [TagDetected.ats].
/// - [setCanvasPixel] and friends build a packed frame for it, in portrait canvas coordinates.
/// - [writeToPanel] sends one over an open [NfcSession], speaking whichever protocol the panel
///   needs. Losing the panel mid-write is ordinary: expect [PanelLost] and [RefreshNotStarted],
///   and offer a retry.
/// - [tagEvents] reports panels arriving and leaving.
///
/// The radio itself is Android-only, and has to be: reader mode with a stretched presence check
/// is the only way these panels stay powered for a whole write.
library;

export 'src/frame_layout.dart';
export 'src/gseries_protocol.dart';
export 'src/nfc_session.dart';
export 'src/panel_device.dart';
export 'src/panel_writer.dart';
export 'src/probe_script.dart';
export 'src/rev22_protocol.dart';
export 'src/tag_events.dart';
export 'src/transport.dart';
