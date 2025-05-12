#!/usr/bin/env python3
"""
A utility script to manage Python virtual environments (venv).

This script simplifies common venv operations:
- Creates a new venv.
- Activates an existing venv.
- Installs dependencies from a requirements.txt file.
- Generates a requirements.txt file.
- Deactivates the current venv.
- Lists existing venvs in the current directory.
- Checks if a venv is active.

Usage:
    python venv_utils.py <command> [options]

Commands:
    create      Create a new virtual environment.
                Options:
                    -n, --name <name>  Name of the virtual environment (default: 'venv').
    activate    Activate an existing virtual environment.
                If no name is provided, it tries to activate 'venv', or the only venv in the directory.
    install     Install dependencies from a requirements.txt file.
                Options:
                    -r, --requirements <file>  Path to the requirements file (default: 'requirements.txt').
    freeze      Generate a requirements.txt file.
                Options:
                    -r, --requirements <file>  Path to the requirements file (default: 'requirements.txt').
    deactivate  Deactivate the current virtual environment.
    list        List existing virtual environments in the current directory.
    check       Check if a virtual environment is currently active.
    help        Display this help message.

Examples:
    python venv_utils.py create -n myenv
    python venv_utils.py activate myenv
    python venv_utils.py install -r requirements.txt
    python venv_utils.py freeze -r requirements.txt
    python venv_utils.py deactivate
    python venv_utils.py list
    python venv_utils.py check
    python venv_utils.py help
"""

import os
import sys
import subprocess
import venv  #  Available in Python 3.3 and later

def create_venv(venv_name="venv"):
    """Create a new virtual environment."""
    try:
        # Use the venv module for creating virtual environments.
        venv_path = os.path.abspath(venv_name)  # Use absolute path
        if os.path.exists(venv_path):
            print(f"Virtual environment already exists at {venv_path}")
            return
        venv.create(venv_path, with_pip=True)  # Create with pip
        print(f"Virtual environment created at {venv_path}")
    except Exception as e:
        print(f"Error creating virtual environment: {e}")
        sys.exit(1)

def activate_venv(venv_name=None):
    """Activate an existing virtual environment."""
    if not venv_name:
        # If no name is provided, try to find a venv named "venv"
        if os.path.exists("venv"):
            venv_name = "venv"
        else:
            # Or, find any venv in the current directory.
            venvs = [d for d in os.listdir() if os.path.isdir(d) and _is_venv(d)]
            if len(venvs) == 1:
                venv_name = venvs[0]
            elif len(venvs) > 1:
                print("Multiple virtual environments found. Please specify which one to activate.")
                list_venvs()
                sys.exit(1)
            else:
                print("No virtual environment found.  Create one using 'create' or specify a name.")
                sys.exit(1)

    if sys.platform == "win32":
        script_path = os.path.join(venv_name, "Scripts", "activate")
    else:
        script_path = os.path.join(venv_name, "bin", "activate")

    if not os.path.exists(script_path):
        print(f"Virtual environment not found at {venv_name}")
        sys.exit(1)

    # We can't directly activate.  Instead, we tell the user how.
    print(f"To activate the virtual environment, run this command in your terminal:")
    if sys.platform == "win32":
        print(f"  {venv_name}\\Scripts\\activate")
    else:
        print(f"  source {venv_name}/bin/activate")
    print("Then, you can use 'install', 'freeze', etc.")

def deactivate_venv():
    """Deactivate the current virtual environment."""
    #  We can't directly deactivate. Instead, we tell the user how.
    print("To deactivate the virtual environment, run this command in your terminal:")
    print("  deactivate")

def install_dependencies(requirements_file="requirements.txt"):
    """Install dependencies from a requirements.txt file."""
    if not _is_venv_active():
        print("Error: No virtual environment is active.  Please activate one first.")
        sys.exit(1)

    if not os.path.exists(requirements_file):
        print(f"Error: Requirements file not found at {requirements_file}")
        sys.exit(1)
    try:
        subprocess.run([sys.executable, "-m", "pip", "install", "-r", requirements_file], check=True)
        print(f"Dependencies installed from {requirements_file}")
    except subprocess.CalledProcessError as e:
        print(f"Error installing dependencies: {e}")
        sys.exit(1)

def freeze_dependencies(requirements_file="requirements.txt"):
    """Generate a requirements.txt file."""
    if not _is_venv_active():
        print("Error: No virtual environment is active.  Please activate one first.")
        sys.exit(1)
    try:
        with open(requirements_file, "w") as f:
            subprocess.run([sys.executable, "-m", "pip", "freeze"], stdout=f, check=True)
        print(f"Dependencies frozen to {requirements_file}")
    except Exception as e:
        print(f"Error freezing dependencies: {e}")
        sys.exit(1)

def list_venvs():
    """List existing virtual environments in the current directory."""
    venvs = [d for d in os.listdir() if os.path.isdir(d) and _is_venv(d)]
    if not venvs:
        print("No virtual environments found in the current directory.")
    else:
        print("Virtual environments in the current directory:")
        for venv_name in venvs:
            print(f"  - {venv_name}")

def check_venv():
    """Check if a virtual environment is currently active."""
    if _is_venv_active():
        print("A virtual environment is currently active.")
    else:
        print("No virtual environment is currently active.")

def _is_venv_active():
    """Check if a virtual environment is active (cross-platform)."""
    return (hasattr(sys, 'real_prefix') or  # Unix
            (hasattr(os, 'getenv') and os.getenv('VIRTUAL_ENV') is not None)) # Windows

def _is_venv(path):
    """Check if a directory is a virtual environment."""
    # Check for common venv directory structure.
    if sys.platform == "win32":
        return os.path.exists(os.path.join(path, "Scripts", "activate.bat"))
    else:
        return os.path.exists(os.path.join(path, "bin", "activate"))

def print_help():
    """Display the help message."""
    print(__doc__)

def main():
    """Main function to parse arguments and call the appropriate function."""
    if len(sys.argv) < 2:
        print_help()
        sys.exit(1)

    command = sys.argv[1]
    if command == "create":
        venv_name = "venv"  # Default name.
        if "-n" in sys.argv or "--name" in sys.argv:
            try:
                index = sys.argv.index("-n") if "-n" in sys.argv else sys.argv.index("--name")
                venv_name = sys.argv[index + 1]
            except IndexError:
                print("Error: --name option requires an argument.")
                sys.exit(1)
        create_venv(venv_name)
    elif command == "activate":
        venv_name = None
        if len(sys.argv) > 2:
            venv_name = sys.argv[2]
        activate_venv(venv_name)
    elif command == "install":
        requirements_file = "requirements.txt" # Default
        if "-r" in sys.argv or "--requirements" in sys.argv:
            try:
                index = sys.argv.index("-r") if "-r" in sys.argv else sys.argv.index("--requirements")
                requirements_file = sys.argv[index + 1]
            except IndexError:
                print("Error: --requirements option requires an argument.")
                sys.exit(1)
        install_dependencies(requirements_file)
    elif command == "freeze":
        requirements_file = "requirements.txt" # Default
        if "-r" in sys.argv or "--requirements" in sys.argv:
            try:
                index = sys.argv.index("-r") if "-r" in sys.argv else sys.argv.index("--requirements")
                requirements_file = sys.argv[index + 1]
            except IndexError:
                print("Error: --requirements option requires an argument.")
                sys.exit(1)
        freeze_dependencies(requirements_file)
    elif command == "deactivate":
        deactivate_venv()
    elif command == "list":
        list_venvs()
    elif command == "check":
        check_venv()
    elif command == "help":
        print_help()
    else:
        print_help()
        print(f"Error: Unknown command '{command}'")
        sys.exit(1)

if __name__ == "__main__":
    main()


