# crowdsec_client.py

"""
Client for interacting with CrowdSec (cscli) and related components.
"""

from typing import List, Tuple

from logger_setup import logger # General logger
from docker_utils import run_docker_command, restart_container
from config import (
    CROWDSEC_LAPI_CONTAINER_NAME,
    CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME, # For restarting bouncer
    TRAEFIK_CONTAINER_NAME # For connectivity test
)

# ================================
# CSCLI COMMAND EXECUTION
# ================================

def run_cscli_command(command_args: List[str], print_output: bool = True) -> Tuple[bool, str, str]:
    """
    Execute a cscli command via docker exec in the CrowdSec LAPI container.

    Args:
        command_args: List of arguments for cscli (e.g., ["decisions", "list"])
        print_output: If True, print stdout/stderr to console.

    Returns:
        Tuple of (success, stdout, stderr)
    """
    if not CROWDSEC_LAPI_CONTAINER_NAME:
        logger.error("CROWDSEC_LAPI_CONTAINER_NAME is not set in config. Cannot run cscli commands.")
        return False, "", "CrowdSec LAPI container name not configured."

    cmd = ["cscli"] + command_args
    logger.info(f"Executing cscli command: {' '.join(cmd)} in container '{CROWDSEC_LAPI_CONTAINER_NAME}'")
    success, stdout, stderr = run_docker_command(CROWDSEC_LAPI_CONTAINER_NAME, cmd)

    if print_output:
        if stdout:
            print(f"cscli STDOUT:\n{stdout}")
        if stderr:
            # cscli often uses stderr for info messages too, so print it regardless of success
            print(f"cscli STDERR:\n{stderr}")
            if not success: # Log as error only if command failed
                 logger.error(f"cscli command failed. STDERR: {stderr}")


    if not success and not print_output: # If not printing, ensure errors are logged
        logger.error(f"cscli command {' '.join(cmd)} failed. STDERR: {stderr}")


    return success, stdout, stderr

# ================================
# CROWDSEC DECISION MANAGEMENT
# ================================

def cs_decisions_list(extra_args: List[str] = None, print_output: bool = True) -> bool:
    """List CrowdSec decisions."""
    args = ["decisions", "list"]
    if extra_args:
        args.extend(extra_args)
    success, _, _ = run_cscli_command(args, print_output=print_output)
    return success

def cs_decisions_list_ip(ip_address: str, print_output: bool = True) -> bool:
    """List decisions for a specific IP."""
    if not ip_address:
        logger.error("IP address cannot be empty for cs_decisions_list_ip.")
        if print_output: print("Error: IP address required.")
        return False
    success, _, _ = run_cscli_command(["decisions", "list", "--ip", ip_address], print_output=print_output)
    return success

def cs_ban_ip(ip_address: str, reason: str, duration: str, print_output: bool = True) -> bool:
    """Ban an IP address."""
    if not all([ip_address, reason, duration]):
        logger.error("IP address, reason, and duration are required for cs_ban_ip.")
        if print_output: print("Error: IP, reason, and duration required.")
        return False
    success, _, _ = run_cscli_command([
        "decisions", "add",
        "--ip", ip_address,
        "--reason", reason,
        "--duration", duration
    ], print_output=print_output)
    return success

def cs_unban_ip(ip_address: str, print_output: bool = True) -> bool:
    """Unban an IP address by IP."""
    if not ip_address:
        logger.error("IP address cannot be empty for cs_unban_ip.")
        if print_output: print("Error: IP address required.")
        return False
    # This command might "fail" (non-zero exit) if the IP is not found, but that's okay.
    # We are interested if the command itself executed without docker/cscli errors.
    success, stdout, stderr = run_cscli_command(["decisions", "delete", "--ip", ip_address], print_output=print_output)
    # Consider success if "INFO: 0 decision(s) deleted" or "decision for ip ... deleted"
    if "decision(s) deleted" in stdout.lower() or "no active decision" in stdout.lower() :
        logger.info(f"cs_unban_ip for {ip_address}: Unban command processed. Details: {stdout} {stderr}")
        return True # Treat as success even if no ban was found
    elif not success:
        logger.error(f"cs_unban_ip for {ip_address} encountered an issue. Details: {stdout} {stderr}")
    return success


def cs_unban_id(decision_id: str, print_output: bool = True) -> bool:
    """Unban by decision ID."""
    if not decision_id:
        logger.error("Decision ID cannot be empty for cs_unban_id.")
        if print_output: print("Error: Decision ID required.")
        return False
    success, _, _ = run_cscli_command(["decisions", "delete", "--id", decision_id], print_output=print_output)
    return success

# ================================
# CROWDSEC COLLECTIONS MANAGEMENT
# ================================

def cs_collections_list(print_output: bool = True) -> bool:
    """List CrowdSec collections."""
    success, _, _ = run_cscli_command(["collections", "list"], print_output=print_output)
    return success

def cs_collections_install(collection_name: str, print_output: bool = True) -> bool:
    """Install a CrowdSec collection."""
    if not collection_name:
        logger.error("Collection name cannot be empty for cs_collections_install.")
        if print_output: print("Error: Collection name required.")
        return False
    success, _, _ = run_cscli_command(["collections", "install", collection_name, "--force"], print_output=print_output) # Added --force
    return success

# ================================
# CROWDSEC HUB MANAGEMENT
# ================================

def cs_hub_update(print_output: bool = True) -> bool:
    """Update CrowdSec hub."""
    success, _, _ = run_cscli_command(["hub", "update"], print_output=print_output)
    return success

def cs_hub_upgrade(collection_name: str = "", print_output: bool = True) -> bool:
    """Upgrade CrowdSec hub items (all or specific collection)."""
    args = ["hub", "upgrade"]
    if collection_name:
        args.append(collection_name)
    success, _, _ = run_cscli_command(args, print_output=print_output)
    return success

# ================================
# CROWDSEC STATUS CHECKS
# ================================

def cs_capi_status(print_output: bool = True) -> bool:
    """Check CrowdSec CAPI status."""
    success, _, _ = run_cscli_command(["capi", "status"], print_output=print_output)
    return success

def cs_bouncers_list(print_output: bool = True) -> bool:
    """List registered bouncers."""
    success, _, _ = run_cscli_command(["bouncers", "list"], print_output=print_output)
    return success

def cs_bouncer_add(bouncer_name: str, api_key: str = None, print_output: bool = True) -> Tuple[bool, str]:
    """Add a new bouncer. If api_key is provided, it tries to add with that key. Otherwise, generates one."""
    if not bouncer_name:
        logger.error("Bouncer name cannot be empty for cs_bouncer_add.")
        if print_output: print("Error: Bouncer name required.")
        return False, ""

    command = ["bouncers", "add", bouncer_name]
    if api_key:
        command.extend(["--key", api_key])

    success, stdout, stderr = run_cscli_command(command, print_output=print_output)
    generated_key = ""
    if success and not api_key: # Extract generated key if we didn't provide one
        # Typical output: "Api key for 'bouncer_name':\n\n   theapikey12345\n\nPlease BLA BLA"
        lines = stdout.splitlines()
        for i, line in enumerate(lines):
            if f"api key for '{bouncer_name.lower()}'" in line.lower() and i + 2 < len(lines):
                generated_key = lines[i+2].strip()
                break
        if generated_key:
            logger.info(f"Successfully added bouncer '{bouncer_name}' and extracted API key.")
            if print_output: print(f"Extracted API Key: {generated_key}")
        else:
            logger.warning(f"Added bouncer '{bouncer_name}', but could not parse API key from output: {stdout}")


    return success, generated_key if not api_key else api_key # Return provided key if used

def cs_bouncer_delete(bouncer_name: str, print_output: bool = True) -> bool:
    """Delete a bouncer."""
    if not bouncer_name:
        logger.error("Bouncer name cannot be empty for cs_bouncer_delete.")
        if print_output: print("Error: Bouncer name required.")
        return False
    success, _, _ = run_cscli_command(["bouncers", "delete", bouncer_name], print_output=print_output)
    return success

# ================================
# RELATED CONTAINER MANAGEMENT (Restart actions)
# ================================

def cs_restart_lapi_container() -> bool:
    """Restart the CrowdSec LAPI container."""
    if not CROWDSEC_LAPI_CONTAINER_NAME:
        logger.error("CROWDSEC_LAPI_CONTAINER_NAME is not set. Cannot restart LAPI container.")
        return False
    logger.info(f"Attempting to restart CrowdSec LAPI container: {CROWDSEC_LAPI_CONTAINER_NAME}")
    return restart_container(CROWDSEC_LAPI_CONTAINER_NAME)

def cs_restart_bouncer_container() -> bool:
    """Restart the CrowdSec Traefik Bouncer container."""
    if not CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME:
        logger.error("CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME is not set. Cannot restart bouncer container.")
        return False
    logger.info(f"Attempting to restart CrowdSec Traefik Bouncer container: {CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME}")
    return restart_container(CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME)


# ================================
# CONNECTIVITY TESTS
# ================================
def test_bouncer_connectivity(bouncer_url: str = "http://crowdsec-bouncer:8080/api/v1/forwardAuth") -> bool:
    """
    Test connectivity to the bouncer's forwardAuth endpoint from within the Traefik container.
    Assumes the bouncer service is named 'crowdsec-bouncer' inside the Docker network accessible by Traefik.
    The `bouncer_url` parameter allows overriding the bouncer's address if needed.
    """
    if not TRAEFIK_CONTAINER_NAME:
        logger.error("TRAEFIK_CONTAINER_NAME is not set. Cannot test bouncer connectivity.")
        return False

    logger.info(f"Testing bouncer connectivity from Traefik container ('{TRAEFIK_CONTAINER_NAME}') to '{bouncer_url}'...")

    # Try curl first, then wget. Curl is generally preferred for this.
    # -I: head request, -s: silent, -S: show error, -f: fail fast, --connect-timeout
    curl_cmd = ["curl", "-IsS", "--fail", "--connect-timeout", "5", bouncer_url]
    wget_cmd = ["wget", "--spider", "-S", "--timeout=5", "-q", "-O", "/dev/null", bouncer_url] # -q for quiet, -O /dev/null to not save

    success_curl, stdout_curl, stderr_curl = run_docker_command(TRAEFIK_CONTAINER_NAME, curl_cmd, timeout=10)

    if success_curl:
        logger.info(f"Bouncer connectivity test PASSED using curl from '{TRAEFIK_CONTAINER_NAME}' to '{bouncer_url}'.")
        # Example stdout_curl for HEAD: HTTP/1.1 401 Unauthorized
        # We are checking reachability, not necessarily a 200 OK if auth is needed.
        # curl --fail will exit non-zero for 4xx/5xx, but if it connects that's good.
        # Let's refine: success_curl means curl exited 0. If it's HEAD, it might be 401 and still exit 0 if --fail is not used carefully.
        # For now, if `run_docker_command` says success (exit 0), it means curl executed.
        # The actual HTTP status is in stdout/stderr.
        if stdout_curl: logger.debug(f"Curl stdout: {stdout_curl}")
        if stderr_curl: logger.debug(f"Curl stderr: {stderr_curl}") # curl -sS sends errors to stderr
        return True
    else:
        logger.warning(f"Bouncer connectivity test with curl from '{TRAEFIK_CONTAINER_NAME}' to '{bouncer_url}' failed or curl not available.")
        logger.debug(f"Curl stdout: {stdout_curl}")
        logger.debug(f"Curl stderr: {stderr_curl}")

        logger.info(f"Trying wget for bouncer connectivity test from '{TRAEFIK_CONTAINER_NAME}' to '{bouncer_url}'...")
        success_wget, stdout_wget, stderr_wget = run_docker_command(TRAEFIK_CONTAINER_NAME, wget_cmd, timeout=10)
        if success_wget:
            logger.info(f"Bouncer connectivity test PASSED using wget from '{TRAEFIK_CONTAINER_NAME}' to '{bouncer_url}'.")
            if stdout_wget: logger.debug(f"Wget stdout: {stdout_wget}") # wget -S prints headers to stderr
            if stderr_wget: logger.debug(f"Wget stderr: {stderr_wget}")
            return True
        else:
            logger.error(f"Bouncer connectivity test FAILED using both curl and wget from '{TRAFIK_CONTAINER_NAME}' to '{bouncer_url}'.")
            logger.debug(f"Wget stdout: {stdout_wget}")
            logger.debug(f"Wget stderr: {stderr_wget}")
            return False
