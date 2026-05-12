#!/bin/bash

# Exit immediately if any command returns a non-zero status
set -e

# Define the subfolders in the required sequence
SUBFOLDERS=("crossbar" "axis_wrapper" "end_system")

# Store the starting directory
ROOT_DIR=$(pwd)

echo "Starting sequential Vivado builds..."

for folder in "${SUBFOLDERS[@]}"; do
    echo ""
    echo "===================================================="
    echo " Entering: $folder"
    echo "===================================================="

    # Check if the directory exists
    if [ -d "$folder" ]; then
        cd "$folder"

        # Check if the build script exists
        if [ -f "vivado_build.sh" ]; then
            echo "Executing vivado_build.sh in $folder..."
            
            # Ensure the script has execution permissions
            chmod +x vivado_build.sh
            
            # Run the script
            ./vivado_build.sh
            
            echo "Successfully finished build in $folder."
        else
            echo "Error: vivado_build.sh not found in $folder"
            exit 1
        fi

        # Go back to the root directory to start the next iteration
        cd "$ROOT_DIR"
    else
        echo "Error: Directory '$folder' does not exist."
        exit 1
    fi
done

echo ""
echo "===================================================="
echo " All builds completed successfully!"
echo "===================================================="
