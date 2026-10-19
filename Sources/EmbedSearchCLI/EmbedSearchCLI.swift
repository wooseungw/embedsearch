import ArgumentParser

@main
struct EmbedSearchCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embedsearch-cli",
        abstract: "EmbedSearch developer tools: embedding parity, benchmarks, indexing, search and evaluation.",
        subcommands: [EmbedCommand.self, ParityCommand.self, BenchCommand.self,
                      IndexCommand.self, SearchCommand.self, EvalCommand.self]
    )
}
