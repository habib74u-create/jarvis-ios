import Foundation

class SecureAPIService {
    static let shared = SecureAPIService()
    
    private let defaults = UserDefaults(suiteName: AppConfig.appGroupId)
    
    private init() {}
    
    func getOpenAIKey() -> String? {
        return defaults?.string(forKey: AppConfig.Keys.openAIApiKey)
    }
    
    func setOpenAIKey(_ key: String) {
        defaults?.set(key, forKey: AppConfig.Keys.openAIApiKey)
    }
    
    func getDeepgramKey() -> String? {
        return defaults?.string(forKey: AppConfig.Keys.deepgramApiKey)
    }
    
    func setDeepgramKey(_ key: String) {
        defaults?.set(key, forKey: AppConfig.Keys.deepgramApiKey)
    }

    // Cloud backend (optional) — when both are set, JarvisCore routes
    // Gemini requests through this backend instead of calling Gemini
    // directly from the device. Lets Mac/iOS/Windows/Android all share
    // one backend and one set of provider keys.
    func getBackendURL() -> String? {
        return defaults?.string(forKey: AppConfig.Keys.backendURL)
    }

    func setBackendURL(_ url: String) {
        defaults?.set(url, forKey: AppConfig.Keys.backendURL)
    }

    func getBackendAuthToken() -> String? {
        return defaults?.string(forKey: AppConfig.Keys.backendAuthToken)
    }

    func setBackendAuthToken(_ token: String) {
        defaults?.set(token, forKey: AppConfig.Keys.backendAuthToken)
    }
    
    // Add other keys as needed
}
