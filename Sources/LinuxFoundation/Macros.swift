// Macro declarations. Mirrors FoundationModels (SDK 27).

@attached(member, names: arbitrary)
@attached(extension, conformances: Generable)
public macro Generable(description: String? = nil) =
    #externalMacro(module: "LinuxFoundationMacros", type: "GenerableMacro")

@attached(peer)
public macro Guide(description: String) =
    #externalMacro(module: "LinuxFoundationMacros", type: "GuideMacro")

@attached(peer)
public macro Guide<T>(description: String? = nil, _ guides: GenerationGuide<T>...) =
    #externalMacro(module: "LinuxFoundationMacros", type: "GuideMacro") where T: Generable
