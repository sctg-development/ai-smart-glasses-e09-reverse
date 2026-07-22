/*
 * MIT License
 *
 * Copyright (c) 2026 Ronan Le Meillat - SCTG Development
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import Foundation

// MARK: - Data Models

/// Output mode for controlling notification display verbosity
public enum OutputMode {
    case light    // Just dots (default)
    case normal   // Truncated output (20 bytes max)
    case debug    // Full output
}

/// Command execution mode
public enum ExecutionMode {
    case diagnostic
    case help
    case list
    case validate
}

/// Test definition structure
public struct TestDefinition {
    public let swiftName: String
    public let displayName: String
    public let description: String
    public let function: () -> Bool
    
    public init(swiftName: String, displayName: String, description: String, function: @escaping () -> Bool) {
        self.swiftName = swiftName
        self.displayName = displayName
        self.description = description
        self.function = function
    }
}

/// Command line argument parser
public struct CLI {
    public let executionMode: ExecutionMode
    public let outputMode: OutputMode
    public let targetName: String
    public let specificTestNames: [String]?
    
    public init(
        executionMode: ExecutionMode = .diagnostic,
        outputMode: OutputMode = .light,
        targetName: String = "E09",
        specificTestNames: [String]? = nil
    ) {
        self.executionMode = executionMode
        self.outputMode = outputMode
        self.targetName = targetName
        self.specificTestNames = specificTestNames
    }
    
    public static func parseArguments() -> CLI {
        var executionMode: ExecutionMode = .diagnostic
        var outputMode: OutputMode = .light
        var targetName = "E09"
        var specificTestNames: [String]? = nil
        
        let args = CommandLine.arguments
        
        // Skip the first argument (program name)
        var i = 1
        while i < args.count {
            let arg = args[i]
            
            switch arg {
            // Execution mode flags
            case "--help", "-h":
                executionMode = .help
            case "--list", "-l":
                executionMode = .list
            case "--validate", "-v":
                executionMode = .validate
            case "--test":
                // Next argument should be the test names
                if i + 1 < args.count {
                    let testList = args[i + 1]
                    specificTestNames = testList.components(separatedBy: ",")
                    executionMode = .validate // --test implies validation mode
                    i += 1 // Skip the next argument since we've processed it
                }
            
            // Output mode flags
            case "--debug":
                outputMode = .debug
            case "--verbose":
                outputMode = .normal
            
            // Target name (non-flag argument)
            default:
                if !arg.hasPrefix("--") && !arg.hasPrefix("-") {
                    targetName = arg
                }
            }
            i += 1
        }
        
        return CLI(
            executionMode: executionMode,
            outputMode: outputMode,
            targetName: targetName,
            specificTestNames: specificTestNames
        )
    }
    
    public func displayHelp() {
        print("""
        Usage: e09_reverse [OPTIONS] [TARGET_NAME]
        
        Options:
          --help, -h           Display this help message
          --list, -l           List all available tests with their Swift names and descriptions
          --validate, -v       Run all validation tests
          --test TEST_NAMES    Run specific tests only (comma-separated Swift test names)
          --verbose            Display truncated frame data (20 bytes max)
          --debug              Display full frame data
          
        Output modes:
          No flag              Light mode: shows dots for each notification
          --verbose            Normal mode: truncated output (20 bytes max)
          --debug              Debug mode: full frame data
          
        Examples:
          e09_reverse                          # Diagnostic mode with light output
          e09_reverse --help                   # Show this help
          e09_reverse --list                   # List all tests
          e09_reverse --validate               # Run all validation tests
          e09_reverse --test validateBattery,probeDevicePhotoRecognition  # Run specific tests
          e09_reverse E09 --verbose            # Diagnostic mode with truncated output
          e09_reverse E09 --debug              # Diagnostic mode with full frame data
          
        Target name defaults to 'E09' if not specified.
        """)
    }
    
    public func displayTestList(tests: [TestDefinition]) {
        print("Available Tests:")
        print("================")
        print("")
        
        for test in tests {
            print("Swift Name: \(test.swiftName)")
            print("  Display Name: \(test.displayName)")
            print("  Description:  \(test.description)")
            print("")
        }
        
        print("Total: \(tests.count) tests available")
    }
}