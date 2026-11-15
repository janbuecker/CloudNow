/// The one thing the video pipeline needs from the ICE/DTLS bundle: a thread-safe write onto
/// `control_channel_partially_reliable`, which carries frame acks (`0x204`), pacing reports
/// (`0x203`) and RTP NACK requests (`0x0317`). Returns false when the channel is not open.
nonisolated protocol NvstPartiallyReliableControlSending: AnyObject, Sendable {
    func sendPartiallyReliableControl(_ command: NvstControlCommand) -> Bool
}
