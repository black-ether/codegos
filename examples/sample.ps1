#region Initialization
# Load required modules
Import-Module SomeModule

# Configure environment
    # Read configuration
    $config = Get-Content config.json
    # Validate configuration
    if (!$config) { throw 'Missing config' }

# Run application
Start-Process app.exe
#endregion
