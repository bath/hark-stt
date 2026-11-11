/// The speech-to-text models the user can choose from. Both run on this Mac.
/// Do not rename a case: its name is the stored setting.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// OpenAI Whisper large-v3-turbo, through whisper.cpp.
    case whisper
    /// NVIDIA Parakeet TDT 0.6B v2 (English), through Core ML.
    case parakeet

    public var title: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        }
    }

    public var detail: String {
        switch self {
        case .whisper: "OpenAI Whisper large-v3-turbo"
        case .parakeet: "NVIDIA Parakeet TDT 0.6B v2, English only"
        }
    }

    /// The size of the download.
    public var megabytes: Int {
        switch self {
        case .whisper: 574
        case .parakeet: 464
        }
    }
}
