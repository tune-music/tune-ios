enum TuneChannel {
    static let linkScheme: String = {
        #if TUNE_DEV
        "tune-dev"
        #else
        "tune"
        #endif
    }()
}
