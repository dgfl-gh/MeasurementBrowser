# MeasurementBrowser.jl

A modern web-based GUI for browsing and analyzing semiconductor measurement data. Built with Bonito.jl for a responsive desktop application experience.

## Features

- **Device-centric organization**: Automatically organizes measurements by Chip → Subsite → Device hierarchy
- **Interactive GUI**: Modern web-based interface with expandable device tree
- **Real-time plotting**: Click on measurements to instantly view full plots
- **Measurement thumbnails**: Quick preview of each measurement
- **Chronological sorting**: Measurements sorted by acquisition time
- **Rich metadata**: View measurement parameters, timestamps, and statistics
- **Modular design**: Clean separation of parsing, data management, and visualization

## Architecture

```
MeasurementBrowser/
├── MeasurementBrowser.jl    # Main module
├── Project.toml             # Dependencies
├── demo.jl                  # Demo script
├── README.md               # This file
└── src/
    ├── DeviceParser.jl      # Parse device hierarchy from filenames
    ├── MeasurementData.jl   # Data structures and scanning
    ├── PlotGenerator.jl     # Generate plots and thumbnails
    └── BonitoInterface.jl   # Main GUI interface
```

## GUI Layout

```
┌─────────────┬─────────────┬─────────────────────┐
│   Device    │ Measurement │                     │
│    Tree     │    List     │    Plot Area        │
│             │             │                     │
│ 📁 Chip A2  │ 📊 I-V 1V   │  [Interactive Plot] │
│  📂 VII     │ 📊 FE PUND  │                     │
│   🔧 B6     │ 📊 TLM      │                     │
│   🔧 B7     │             │                     │
│  📂 XI      │             │                     │
│   🔧 A1A2   │             │                     │
├─────────────┼─────────────┼─────────────────────┤
│             │      Information Panel             │
│             │  Device details, parameters, etc.  │
└─────────────┴─────────────────────────────────────┘
```

## Usage

### Basic Usage
```julia
using MeasurementBrowser

# Start browser with default settings
server = start_browser("/path/to/measurement/data")
# Opens http://localhost:8000 in browser
```

### Command Line
```bash
julia demo.jl /path/to/measurement/data
```

### Programmatic Usage
```julia
using MeasurementBrowser

# Scan directory structure
hierarchy = scan_directory("/path/to/data")

# Get statistics for a device
device_measurements = hierarchy.chips["A2"]["VII"]["B6"]
stats = get_device_stats(device_measurements)

# Filter measurements
filtered = filter_measurements(
    hierarchy.all_measurements,
    measurement_type="I-V Sweep",
    parameter_filters=Dict("voltage" => (1.0, 2.0))
)
```

## Dependencies

- **Bonito.jl**: Modern web-based GUI framework
- **WGLMakie.jl**: WebGL plotting backend
- **DataFrames.jl**: Data manipulation
- **Observables.jl**: Reactive programming
- **Dates.jl**: Timestamp handling
- **JSON3.jl**: Data serialization

## Supported Measurement Types

- **I-V Sweep**: Current-voltage characteristics
- **FE PUND**: Ferroelectric positive-up-negative-down measurements
- **TLM 4-Point**: Transmission line method resistance measurements
- **Breakdown**: Dielectric breakdown measurements
- **Wakeup**: Ferroelectric wakeup measurements

## Device Naming Convention

The browser parses device information from filenames using patterns like:
- `RuO2test_A2_VII_B6(1)` → Chip: A2, Subsite: VII, Device: B6
- `RuO2test_A2_XI_TLML800W2(1)` → Chip: A2, Subsite: XI, Device: TLML800W2

## Installation

1. Clone or copy the MeasurementBrowser directory
2. Navigate to the directory
3. Install dependencies:
```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

## Development

The package is designed to be modular and extensible:

- **Add new measurement types**: Extend `DeviceParser.jl` and `PlotGenerator.jl`
- **Custom device naming**: Modify parsing patterns in `DeviceParser.jl`
- **New plot types**: Add functions to `PlotGenerator.jl`
- **GUI enhancements**: Extend `BonitoInterface.jl`

## Integration with Existing Code

The browser integrates with existing RuO2 analysis scripts by:
- Reusing data reading functions from `RuO2Data.jl`
- Reusing plotting functions from `RuO2Plots.jl`
- Maintaining compatibility with existing file formats
- Supporting the same measurement types and parameters
