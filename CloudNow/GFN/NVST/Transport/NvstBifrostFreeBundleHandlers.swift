import Foundation

extension NvstBifrostFreeTransport {
    /// Wires the bundle's channel callbacks back into the transport actor. Called before the
    /// bundle is prepared, so no callback can fire into an unassigned slot.
    func installBundleHandlers(_ bundle: NvstWebRtcBundle,
                               sender: NvstFeedbackSender,
                               logger: (@Sendable (String) -> Void)?)
    {
        bundleGeneration &+= 1
        let generation = bundleGeneration
        installBundleNotificationHandlers(bundle, generation: generation)
        bundle.onRemoteAudio = { [weak self] count in
            logger?("NVST bundle seat offered \(count) audio track(s)")
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.noteRemoteAudio(trackCount: count)
                }
            }
        }
        bundle.onPartiallyReliableControlOpen = { [weak self] in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.startQosFeedback()
                }
            }
        }
        bundle.onControlChannelOpen = { [weak self] in
            // The seat starts its 10 s client-timeout the moment the SCTP association is up, so the
            // first pingBackAck gets its own task rather than queueing behind the state announce.
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.startControlKeepAlive()
                }
            }
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.announceClientState()
                    // The seat's protocol version normally arrives after this channel opens, but
                    // nothing orders the two callbacks; whichever lands second runs the chain.
                    transport.activateInputIfReady()
                }
            }
        }
        bundle.onFeedbackChannelOpen = { [weak self] in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.logger?("NVST feedback channel open; starting receiver reports")
                    sender.start()
                    transport.adoptFeedbackSender(sender)
                    // Normally already punching since the ANNOUNCE-ready hook; idempotent.
                    transport.beginVideoHolePunch()
                }
            }
        }
        bundle.onConnectionFailure = { [weak self] message in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleBundleConnectionFailure(message)
                }
            }
        }
    }

    private func installBundleNotificationHandlers(_ bundle: NvstWebRtcBundle, generation: UInt64) {
        bundle.onInputProtocolNegotiated = { [weak self] version in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.inputDidNegotiate(version)
                }
            }
        }
        bundle.onSeatStats = { [weak self] stats in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.recordSeatStats(stats)
                }
            }
        }
        bundle.onHapticEvents = { [weak self] events in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleHapticEvents(events)
                }
            }
        }
        bundle.onHdrMode = { [weak self] notification in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleHdrMode(notification)
                }
            }
        }
        bundle.onSeatTermination = { [weak self] termination in
            Task {
                await self?.withCurrentBundleGeneration(generation) { transport in
                    transport.handleSeatTermination(termination)
                }
            }
        }
    }
}
