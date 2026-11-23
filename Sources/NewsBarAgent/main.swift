import Foundation
import NewsBar

let status = await runNewsBarAgent(arguments: CommandLine.arguments)
exit(status)
