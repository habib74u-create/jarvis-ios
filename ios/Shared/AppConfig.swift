import Foundation

struct AppConfig {
    // REPLACE THIS WITH YOUR ACTUAL APP GROUP ID
    static let appGroupId = "group.ceo.jarvis.ios"
    
    struct Keys {
        static let openAIApiKey = "openai_api_key"
        static let deepgramApiKey = "deepgram_api_key"
        static let anthropicApiKey = "anthropic_api_key"
        static let geminiApiKey = "gemini_api_key"
        static let backendURL = "backend_url"
        static let backendAuthToken = "backend_auth_token"
    }
}
