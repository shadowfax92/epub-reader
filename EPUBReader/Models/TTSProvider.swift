import Foundation

enum TTSProviderType: String, CaseIterable, Identifiable {
    case elevenLabs = "elevenlabs"
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        }
    }
}

struct OpenAIVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String

    static let allVoices: [OpenAIVoice] = [
        OpenAIVoice(id: "alloy", name: "Alloy", description: "Neutral and balanced"),
        OpenAIVoice(id: "ash", name: "Ash", description: "Soft and conversational"),
        OpenAIVoice(id: "ballad", name: "Ballad", description: "Warm and expressive"),
        OpenAIVoice(id: "coral", name: "Coral", description: "Clear and bright"),
        OpenAIVoice(id: "echo", name: "Echo", description: "Smooth and resonant"),
        OpenAIVoice(id: "fable", name: "Fable", description: "Warm and narrative"),
        OpenAIVoice(id: "marin", name: "Marin", description: "Light and airy"),
        OpenAIVoice(id: "cedar", name: "Cedar", description: "Deep and authoritative"),
        OpenAIVoice(id: "nova", name: "Nova", description: "Friendly and energetic"),
        OpenAIVoice(id: "onyx", name: "Onyx", description: "Deep and commanding"),
        OpenAIVoice(id: "sage", name: "Sage", description: "Calm and measured"),
        OpenAIVoice(id: "shimmer", name: "Shimmer", description: "Clear and articulate"),
        OpenAIVoice(id: "verse", name: "Verse", description: "Dynamic and engaging"),
    ]
}
