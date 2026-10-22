#!/bin/bash
# Build script for AO Test Decision Environment
#
# This script builds a Decision Environment that includes the current
# ansible-rulebook code with the new run_ao_workflow action.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
DE_NAME="${DE_NAME:-ao-test-de}"
DE_TAG="${DE_TAG:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
BUILD_ARGS="${BUILD_ARGS:---no-cache}"
DE_MULTIARCH="${DE_MULTIARCH:-false}"
DE_PLATFORM="${DE_PLATFORM:-linux/amd64}"  # Default to amd64 for AAP compatibility
SKIP_TESTS="${SKIP_TESTS:-false}"  # Set to true to skip tests before pushing

# Registry configuration
REGISTRY="${REGISTRY:-quay.io}"
REGISTRY_USER="${REGISTRY_USER:-bgrimmet}"
REGISTRY_REPO="${REGISTRY_REPO:-ansible-rulebook/ao-de}"
FULL_IMAGE_NAME="${REGISTRY}/${REGISTRY_USER}/${REGISTRY_REPO}"

# Generate timestamp tag (YYYY-MM-DD-HHMMSS)
TIMESTAMP_TAG=$(date +%Y-%m-%d-%H%M%S)

# Clean up old local builds to prevent conflicts
echo "Cleaning up old local builds..."

# List existing images/manifests for debugging
echo "Existing images matching pattern:"
$CONTAINER_RUNTIME images | grep "${DE_NAME}" || echo "  None found"
echo ""

# Remove all existing images and manifests matching the DE name
# This ensures a clean slate
CLEANED=0
for tag_suffix in "" "-amd64" "-arm64"; do
    for prefix in "" "localhost/"; do
        IMAGE_NAME="${prefix}${DE_NAME}:${DE_TAG}${tag_suffix}"
        # Try manifest remove first
        if $CONTAINER_RUNTIME manifest rm "${IMAGE_NAME}" 2>/dev/null; then
            echo "  Removed manifest: ${IMAGE_NAME}"
            CLEANED=1
        fi
        # Then force remove the image
        if $CONTAINER_RUNTIME rmi -f "${IMAGE_NAME}" 2>/dev/null; then
            echo "  Removed image: ${IMAGE_NAME}"
            CLEANED=1
        fi
    done
done

# Also remove any dangling manifests with the same name pattern
if $CONTAINER_RUNTIME manifest ls 2>/dev/null | grep -q "${DE_NAME}"; then
    $CONTAINER_RUNTIME manifest ls 2>/dev/null | grep "${DE_NAME}" | awk '{print $1":"$2}' | while read manifest; do
        if $CONTAINER_RUNTIME manifest rm "$manifest" 2>/dev/null; then
            echo "  Removed manifest: $manifest"
            CLEANED=1
        fi
    done
fi

if [ $CLEANED -eq 0 ]; then
    echo "  No cleanup needed"
fi

echo ""

echo "═══════════════════════════════════════════════════════════"
echo " Building AO Test Decision Environment"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Configuration:"
echo "  Local Image:       ${DE_NAME}:${DE_TAG}"
echo "  Registry Image:    ${FULL_IMAGE_NAME}"
echo "  Timestamp Tag:     ${TIMESTAMP_TAG}"
echo "  Container Runtime: ${CONTAINER_RUNTIME}"
echo "  Build Args:        ${BUILD_ARGS}"
echo "  Multi-arch:        ${DE_MULTIARCH}"
echo "  Run Tests:         $([ "$SKIP_TESTS" = "true" ] && echo "No (SKIP_TESTS=true)" || echo "Yes")"
if [ -n "$DE_PLATFORM" ]; then
    echo "  Platform:          ${DE_PLATFORM}"
else
    echo "  Platform:          native ($(uname -m))"
fi
echo ""

# Check if ansible-builder is installed
if ! command -v ansible-builder &> /dev/null; then
    echo "ERROR: ansible-builder is not installed"
    echo ""
    echo "Install with:"
    echo "  pip install ansible-builder"
    exit 1
fi

# Check if container runtime is available
if ! command -v "$CONTAINER_RUNTIME" &> /dev/null; then
    echo "ERROR: $CONTAINER_RUNTIME is not installed"
    echo ""
    echo "Install podman with:"
    echo "  brew install podman"
    echo "  podman machine init"
    echo "  podman machine start"
    exit 1
fi

# Ensure we're on the feature branch with AO changes
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"
echo ""

# Create a temporary build directory
echo "Creating build directory..."
BUILD_DIR=$(mktemp -d)
echo "   Build directory: $BUILD_DIR"
cd "$BUILD_DIR"

# Copy the DE definition file
cp "$SCRIPT_DIR/ao-test-decision-environment.yml" .

# Copy the current working directory (includes uncommitted changes)
echo "Copying current code (including uncommitted changes)..."
mkdir -p ansible-rulebook-src
rsync -a --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
      --exclude='*.pyc' --exclude='.pytest_cache' --exclude='*.egg-info' \
      --exclude='context' --exclude='.tox' \
      "$SCRIPT_DIR/" ansible-rulebook-src/
echo "   Code copy complete"
echo ""

# Build the Decision Environment
echo "Building Decision Environment..."
echo ""

# Build for native platform or multi-arch
if [ "$DE_MULTIARCH" = "true" ]; then
    echo "Building multi-arch image for linux/amd64 and linux/arm64..."
    echo ""

    # Build for amd64
    echo "Building for linux/amd64..."

    # Create context for amd64
    ansible-builder create -f ao-test-decision-environment.yml -v 3

    # Copy source into ansible-builder's context
    cp -r ansible-rulebook-src context/

    # Build the image
    $CONTAINER_RUNTIME build \
      -f context/Containerfile \
      -t "${DE_NAME}:${DE_TAG}-amd64" \
      $BUILD_ARGS \
      --build-arg ARCH=amd64 \
      context

    # Clean up context for next build
    rm -rf context

    # Build for arm64
    echo "Building for linux/arm64..."

    # Create context for arm64
    ansible-builder create -f ao-test-decision-environment.yml -v 3

    # Copy source into ansible-builder's context
    cp -r ansible-rulebook-src context/

    # Build the image
    $CONTAINER_RUNTIME build \
      -f context/Containerfile \
      -t "${DE_NAME}:${DE_TAG}-arm64" \
      $BUILD_ARGS \
      --build-arg ARCH=arm64 \
      context

    # Clean up any existing manifest/image with this tag
    echo "Cleaning up existing manifests/images..."
    $CONTAINER_RUNTIME manifest rm "${DE_NAME}:${DE_TAG}" 2>/dev/null || true
    $CONTAINER_RUNTIME rmi -f "${DE_NAME}:${DE_TAG}" 2>/dev/null || true
    $CONTAINER_RUNTIME manifest rm "localhost/${DE_NAME}:${DE_TAG}" 2>/dev/null || true
    $CONTAINER_RUNTIME rmi -f "localhost/${DE_NAME}:${DE_TAG}" 2>/dev/null || true

    # Create manifest list
    echo "Creating multi-arch manifest..."
    $CONTAINER_RUNTIME manifest create "${DE_NAME}:${DE_TAG}" \
      "${DE_NAME}:${DE_TAG}-amd64" \
      "${DE_NAME}:${DE_TAG}-arm64"

    BUILD_STATUS=$?

    if [ $BUILD_STATUS -eq 0 ]; then
        echo ""
        echo "Multi-arch manifest created. Push with:"
        echo "  $CONTAINER_RUNTIME manifest push ${DE_NAME}:${DE_TAG} <registry>/${DE_NAME}:${DE_TAG}"
    fi
else
    # Standard single-platform build
    if [ -n "$DE_PLATFORM" ]; then
        echo "Building for platform: $DE_PLATFORM"
    fi

    # Use ansible-builder create to generate Containerfile
    echo "Generating Containerfile with ansible-builder..."
    ansible-builder create -f ao-test-decision-environment.yml -v 3

    # Copy our source code into the ansible-builder context
    echo "Adding ansible-rulebook source to build context..."
    cp -r ansible-rulebook-src context/

    # Build the image using the container runtime directly
    echo "Building container image..."
    BUILD_CMD="$CONTAINER_RUNTIME build -f context/Containerfile -t ${DE_NAME}:${DE_TAG} $BUILD_ARGS"

    # Add platform flag if specified
    if [ -n "$DE_PLATFORM" ]; then
        BUILD_CMD="$BUILD_CMD --platform=$DE_PLATFORM"
    fi

    BUILD_CMD="$BUILD_CMD context"

    eval $BUILD_CMD
    BUILD_STATUS=$?
fi

# Cleanup
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

if [ $BUILD_STATUS -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo " Build Successful!"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Image: ${DE_NAME}:${DE_TAG}"
    echo ""

    # Test the Decision Environment before pushing (unless skipped)
    if [ "$SKIP_TESTS" = "true" ]; then
        echo "WARNING: Skipping tests (SKIP_TESTS=true)"
        echo ""
    else
        echo "═══════════════════════════════════════════════════════════"
        echo " Testing Decision Environment"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        TEST_FAILED=0

        # Determine which image to test based on build type
        if [ "$DE_MULTIARCH" = "true" ]; then
            # For multi-arch, test the native architecture image
            ARCH=$(uname -m)
            if [ "$ARCH" = "x86_64" ]; then
                TEST_IMAGE="${DE_NAME}:${DE_TAG}-amd64"
            elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
                TEST_IMAGE="${DE_NAME}:${DE_TAG}-arm64"
            else
                echo "WARNING: Unknown architecture $ARCH, testing may fail"
                TEST_IMAGE="${DE_NAME}:${DE_TAG}-amd64"
            fi
        else
            TEST_IMAGE="${DE_NAME}:${DE_TAG}"
        fi

        echo "Testing image: ${TEST_IMAGE}"
        echo ""

        # Test 1: Verify Python and ansible-rulebook package
        echo "Test 1: Verify ansible-rulebook installation"
        if ! $CONTAINER_RUNTIME run --rm "${TEST_IMAGE}" \
            python3.12 -c "import ansible_rulebook; print('ansible-rulebook package ready')"; then
            echo "FAILED: ansible-rulebook package not found"
            TEST_FAILED=1
        fi
        echo ""

        # Test 2: Verify AO workflow action can be imported
        echo "Test 2: Verify run_ao_workflow action"
        if ! $CONTAINER_RUNTIME run --rm "${TEST_IMAGE}" \
            python3.12 -c "from ansible_rulebook.action.run_ao_workflow import RunAOWorkflow; print('RunAOWorkflow action ready')"; then
            echo "FAILED: RunAOWorkflow action cannot be imported"
            TEST_FAILED=1
        fi
        echo ""

        # Test 3: Verify AO workflow runner with OAuth2 support
        echo "Test 3: Verify AOWorkflowRunner OAuth2 support"
        if ! $CONTAINER_RUNTIME run --rm "${TEST_IMAGE}" \
            python3.12 -c "from ansible_rulebook.ao_workflow_runner import AOWorkflowRunner; runner = AOWorkflowRunner(client_id='test', client_secret='test'); print('AOWorkflowRunner OAuth2 initialization successful')"; then
            echo "FAILED: AOWorkflowRunner OAuth2 support not working"
            TEST_FAILED=1
        fi
        echo ""

        # Test 4: Verify ansible-rulebook CLI exists
        echo "Test 4: Verify ansible-rulebook CLI"
        if ! $CONTAINER_RUNTIME run --rm "${TEST_IMAGE}" \
            ansible-rulebook --version; then
            echo "FAILED: ansible-rulebook CLI not found"
            TEST_FAILED=1
        fi
        echo ""

        # Test 5: Run unit tests for AO integration (if pytest available)
        echo "Test 5: Run AO workflow unit tests"
        if $CONTAINER_RUNTIME run --rm "${TEST_IMAGE}" \
            python3.12 -c "import pytest" 2>/dev/null; then
            if ! $CONTAINER_RUNTIME run --rm -v "$(pwd)/tests:/tmp/tests:Z" "${TEST_IMAGE}" \
                python3.12 -m pytest /tmp/tests/unit/test_ao_workflow_runner.py::TestAOWorkflowRunnerAuthentication -v --tb=short 2>&1 | tail -20; then
                echo "FAILED: AO workflow unit tests failed"
                TEST_FAILED=1
            fi
        else
            echo "WARNING: pytest not available, skipping unit tests"
        fi
        echo ""

        if [ $TEST_FAILED -eq 1 ]; then
            echo ""
            echo "═══════════════════════════════════════════════════════════"
            echo " Tests Failed - Skipping Registry Push"
            echo "═══════════════════════════════════════════════════════════"
            echo ""
            echo "The Decision Environment was built but failed tests."
            echo "Fix the issues before pushing to registry."
            echo ""
            echo "Local image available for debugging: ${TEST_IMAGE}"
            exit 1
        fi

        echo "═══════════════════════════════════════════════════════════"
        echo " All Tests Passed!"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
    fi

    # Login to quay.io
    echo "Logging into ${REGISTRY}..."
    if ! $CONTAINER_RUNTIME login ${REGISTRY}; then
        echo "Failed to login to ${REGISTRY}"
        echo "   Build succeeded but push skipped"
        exit 1
    fi
    echo ""

    if [ "$DE_MULTIARCH" = "true" ]; then
        # Multi-arch: create manifests and push
        echo "Creating multi-arch manifests for registry..."

        # Clean up any existing manifests
        $CONTAINER_RUNTIME manifest rm ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG} 2>/dev/null || true
        $CONTAINER_RUNTIME manifest rm ${FULL_IMAGE_NAME}:latest 2>/dev/null || true

        echo "   Creating manifest ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}"
        $CONTAINER_RUNTIME manifest create ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG} \
          ${DE_NAME}:${DE_TAG}-amd64 \
          ${DE_NAME}:${DE_TAG}-arm64

        echo "   Creating manifest ${FULL_IMAGE_NAME}:latest"
        $CONTAINER_RUNTIME manifest create ${FULL_IMAGE_NAME}:latest \
          ${DE_NAME}:${DE_TAG}-amd64 \
          ${DE_NAME}:${DE_TAG}-arm64
        echo ""

        # Push manifests with all architecture images
        echo "Pushing multi-arch manifests to registry..."
        echo "   Pushing ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG} (with all architectures)"
        if ! $CONTAINER_RUNTIME manifest push --all ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}; then
            echo "Failed to push timestamp manifest"
            exit 1
        fi

        echo "   Pushing ${FULL_IMAGE_NAME}:latest (with all architectures)"
        if ! $CONTAINER_RUNTIME manifest push --all ${FULL_IMAGE_NAME}:latest; then
            echo "Failed to push latest manifest"
            exit 1
        fi
    else
        # Single-arch: tag and push images
        echo "Tagging images..."
        echo "   Tagging as ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}"
        $CONTAINER_RUNTIME tag ${DE_NAME}:${DE_TAG} ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}

        echo "   Tagging as ${FULL_IMAGE_NAME}:latest"
        $CONTAINER_RUNTIME tag ${DE_NAME}:${DE_TAG} ${FULL_IMAGE_NAME}:latest
        echo ""

        # Push both tags
        echo "Pushing to registry..."
        echo "   Pushing ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}"
        if ! $CONTAINER_RUNTIME push ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}; then
            echo "Failed to push timestamp tag"
            exit 1
        fi

        echo "   Pushing ${FULL_IMAGE_NAME}:latest"
        if ! $CONTAINER_RUNTIME push ${FULL_IMAGE_NAME}:latest; then
            echo "Failed to push latest tag"
            exit 1
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo " Build and Push Complete!"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Published images:"
    echo "    ${FULL_IMAGE_NAME}:${TIMESTAMP_TAG}"
    echo "    ${FULL_IMAGE_NAME}:latest"
    if [ "$DE_MULTIARCH" = "true" ]; then
        echo "    Multi-arch: amd64 + arm64"
    fi
    echo ""
    echo "Test locally with:"
    echo "  $CONTAINER_RUNTIME run -it --rm \\"
    echo "    -e EDA_AO_URL='https://your-ao.com' \\"
    echo "    -e EDA_AO_TOKEN='your-token' \\"
    echo "    -v \$(pwd)/test_ao_local.yml:/tmp/rulebook.yml:Z \\"
    echo "    -v \$(pwd)/test_inventory.yml:/tmp/inventory.yml:Z \\"
    echo "    ${FULL_IMAGE_NAME}:latest \\"
    echo "    ansible-rulebook -i /tmp/inventory.yml --rulebook /tmp/rulebook.yml -v"
    echo ""
    echo "Verify AO action:"
    echo "  $CONTAINER_RUNTIME run -it --rm ${FULL_IMAGE_NAME}:latest \\"
    echo "    python3.12 -c \"from ansible_rulebook.action.run_ao_workflow import RunAOWorkflow; print('AO action ready')\""
    echo ""
    echo "Use in AAP:"
    echo "  1. In AAP, add Decision Environment:"
    echo "     Image: ${FULL_IMAGE_NAME}:latest"
    echo "  2. Create Rulebook Activation using this DE"
    echo "  3. Set EDA_AO_* environment variables in the activation"
    echo ""
else
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo " Build Failed"
    echo "═══════════════════════════════════════════════════════════"
    exit 1
fi
