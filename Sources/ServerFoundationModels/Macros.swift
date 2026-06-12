// Macro declarations. Mirrors FoundationModels (SDK 27).

@attached(member, names: arbitrary)
@attached(extension, conformances: Generable)
public macro Generable(description: String? = nil) =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "GenerableMacro")

@attached(peer)
public macro Guide(description: String) =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "GuideMacro")

@attached(peer)
public macro Guide<T>(description: String? = nil, _ guides: GenerationGuide<T>...) =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "GuideMacro") where T: Generable

@attached(peer)
public macro Guide<RegexOutput>(description: String? = nil, _ guides: Regex<RegexOutput>) =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "GuideMacro")

@attached(accessor)
@attached(peer, names: prefixed(__Key_))
public macro SessionPropertyEntry() =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "SessionPropertyEntryMacro")

@attached(accessor)
public macro __SessionPropertyEntryDefaultValue() =
    #externalMacro(module: "ServerFoundationModelsMacros", type: "SessionPropertyEntryDefaultValueMacro")
