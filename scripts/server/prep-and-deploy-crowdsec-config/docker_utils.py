# docker_utils.py

"""
Utilities for interacting with Docker and Docker Compose.
"""

import os
import subprocess
import shutil
import time
from typing import List, Tuple

# It's better to get loggers from logger_setup to avoid circular dependencies
# if they also need config. For now, we assume logger_setup is imported elsewhere (e.g., main)
# and we get the specific dc_logger.
# from logger_setup import dc_logger # This would be ideal if logger_setup doesn't import this.
# For now, let's get it from the global scope if main.py sets it up.
# This is a common challenge in breaking down monolithic scripts.
# A better approach might be to pass logger instances around or use a central logging config.

# Assuming dc_logger is configured and available in the global scope by the main script
# For standalone use, you might need:
# import logging
# dc_logger = logging.getLogger('docker_compose') # and configure it

# For the purpose of this modularization, we will assume dc_logger is available
# as it was in the original script structure (initialized in logger_setup.py and globally accessible)
from logger_setup import dc_logger, logger # Make sure logger_setup is imported first in main

# ================================
# DOCKER COMPOSE OPERATIONS
# ================================

def run_docker_compose_command(command: List[str], cwd: str = None) -> Tuple[bool, str, str]:
    """
    Execute a Docker Compose command and log the output.

    Args:
        command: Docker Compose command as list (e.g., ['docker', 'compose', 'up', '-d'])
        cwd: Working directory for command execution

    Returns:
        Tuple of (success, stdout, stderr)
    """
    if cwd is None:
        cwd = os.getcwd()

    # Use modern 'docker compose' command (Docker Compose V2)
    cmd = command.copy()
    
    # Check if we have docker command available
    if not shutil.which('docker'):
        dc_logger.error("Docker command not found")
        return False, "", "Docker command not found"

    # Ensure we're using 'docker compose' format
    if len(cmd) >= 2 and cmd[0] == 'docker-compose':
        cmd[0] = 'docker'
        cmd[1] = 'compose'
    elif len(cmd) >= 1 and cmd[0] != 'docker':
        # If command doesn't start with 'docker', prepend 'docker compose'
        cmd = ['docker', 'compose'] + cmd

    dc_logger.info(f"Executing: {' '.join(cmd)} in {cwd}")

    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=120  # 2 minute timeout
        )

        success = result.returncode == 0
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()

        if stdout:
            dc_logger.info(f"STDOUT: {stdout}")
        if stderr:
            # Log stderr as error only if the command failed
            if not success:
                dc_logger.error(f"STDERR: {stderr}")
            else:
                dc_logger.info(f"STDERR (possibly warnings): {stderr}")

        dc_logger.info(f"Command {'SUCCEEDED' if success else 'FAILED'} (exit code: {result.returncode})")

        return success, stdout, stderr

    except subprocess.TimeoutExpired:
        dc_logger.error("Docker Compose command timed out")
        return False, "", "Command timed out"
    except Exception as e:
        dc_logger.error(f"Exception executing Docker Compose command: {e}")
        return False, "", str(e)

def docker_compose_down(cwd: str = None, compose_file: str = None) -> bool:
    """Stop and remove containers using Docker Compose."""
    cmd = ['docker', 'compose']
    if compose_file:
        cmd.extend(['-f', compose_file])
    cmd.append('down')
    success, _, _ = run_docker_compose_command(cmd, cwd)
    return success

def docker_compose_up(cwd: str = None, compose_file: str = None) -> bool:
    """Start containers using Docker Compose."""
    cmd = ['docker', 'compose']
    if compose_file:
        cmd.extend(['-f', compose_file])
    cmd.extend(['up', '-d', '--remove-orphans'])
    success, _, _ = run_docker_compose_command(cmd, cwd)
    return success

def restart_docker_compose_stack(cwd: str = None, compose_file: str = None) -> bool:
    """Restart the entire Docker Compose stack."""
    dc_logger.info("Restarting Docker Compose stack...")

    if not docker_compose_down(cwd, compose_file):
        dc_logger.error("Failed to stop containers")
        return False

    # Brief pause between down and up
    time.sleep(2)

    if not docker_compose_up(cwd, compose_file):
        dc_logger.error("Failed to start containers")
        return False

    dc_logger.info("Docker Compose stack restarted successfully")
    return True

# ================================
# DOCKER OPERATIONS (for cscli via docker exec)
# ================================

def run_docker_command(container_name: str, command: List[str], timeout: int = 30) -> Tuple[bool, str, str]:
    """
    Execute a command in a Docker container.

    Returns:
        Tuple of (success, stdout, stderr)
    """
    cmd = ["docker", "exec", container_name] + command
    logger.debug(f"Executing Docker command: {' '.join(cmd)}") # Using general logger

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )

        success = result.returncode == 0
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()

        if stdout:
            logger.debug(f"STDOUT: {stdout}")
        if stderr:
            # Log stderr as error only if the command failed
            if not success:
                logger.error(f"STDERR: {stderr}")
            else:
                logger.info(f"STDERR (possibly warnings): {stderr}")

        logger.debug(f"Command {'SUCCEEDED' if success else 'FAILED'} (exit code: {result.returncode})")

        return success, stdout, stderr

    except subprocess.TimeoutExpired:
        logger.error(f"Docker command '{' '.join(command)}' in container '{container_name}' timed out")
        return False, "", "Command timed out"
    except Exception as e:
        logger.error(f"Exception executing Docker command '{' '.join(command)}' in container '{container_name}': {e}")
        return False, "", str(e)

def restart_container(container_name: str) -> bool:
    """Restart a Docker container."""
    logger.info(f"Attempting to restart container '{container_name}'...")
    try:
        result = subprocess.run(
            ["docker", "restart", container_name],
            capture_output=True,
            text=True,
            timeout=60  # Increased timeout for restart
        )
        success = result.returncode == 0
        if success:
            logger.info(f"Container '{container_name}' restarted successfully. STDOUT: {result.stdout.strip()}")
        else:
            logger.error(f"Failed to restart container '{container_name}': STDERR: {result.stderr.strip()}")
        return success
    except subprocess.TimeoutExpired:
        logger.error(f"Timeout restarting container '{container_name}'")
        return False
    except Exception as e:
        logger.error(f"Exception restarting container '{container_name}': {e}")
        return False

# ================================
# OPTIONAL: SOURCED ENVIRONMENT SUPPORT
# ================================

def run_docker_compose_with_sourced_env(command: List[str], cwd: str = None, source_file: str = "/root/.bashrc") -> Tuple[bool, str, str]:
    """
    Execute a Docker Compose command with sourced environment (e.g., for 'dc' alias).
    This is an alternative function that sources bashrc before running commands.
    
    Args:
        command: Docker Compose command as list
        cwd: Working directory for command execution
        source_file: File to source before running command (default: /root/.bashrc)
        
    Returns:
        Tuple of (success, stdout, stderr)
    """
    if cwd is None:
        cwd = os.getcwd()

    # Create a bash command that sources the file and runs the docker compose command
    cmd_str = ' '.join(command)
    bash_command = f"source {source_file} && {cmd_str}"
    
    dc_logger.info(f"Executing with sourced env: {bash_command} in {cwd}")

    try:
        result = subprocess.run(
            ["bash", "-c", bash_command],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=120  # 2 minute timeout
        )

        success = result.returncode == 0
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()

        if stdout:
            dc_logger.info(f"STDOUT: {stdout}")
        if stderr:
            # Log stderr as error only if the command failed
            if not success:
                dc_logger.error(f"STDERR: {stderr}")
            else:
                dc_logger.info(f"STDERR (possibly warnings): {stderr}")

        dc_logger.info(f"Command {'SUCCEEDED' if success else 'FAILED'} (exit code: {result.returncode})")

        return success, stdout, stderr

    except subprocess.TimeoutExpired:
        dc_logger.error("Docker Compose command with sourced env timed out")
        return False, "", "Command timed out"
    except Exception as e:
        dc_logger.error(f"Exception executing Docker Compose command with sourced env: {e}")
        return False, "", str(e)
