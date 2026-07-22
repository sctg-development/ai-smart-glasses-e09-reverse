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

// MARK: - Application Entry Point

// Parse command line arguments
let cli = CLI.parseArguments()

// Handle special modes
switch cli.executionMode {
case .help:
    cli.displayHelp()
    exit(0)
case .list:
    cli.displayTestList(tests: BleProbe.allTests.map { 
        TestDefinition(swiftName: $0.swiftName, displayName: $0.displayName, description: $0.description, function: { false })
    })
    exit(0)
case .validate, .diagnostic:
    break // Continue with normal execution
}

// Create an instance of BleProbe and start the BLE discovery process
// The RunLoop.main.run() keeps the application running to handle asynchronous BLE events
let probe = BleProbe(
    specificTestNames: cli.specificTestNames,
    outputMode: cli.outputMode,
    targetName: cli.targetName
)
probe.start()
RunLoop.main.run()