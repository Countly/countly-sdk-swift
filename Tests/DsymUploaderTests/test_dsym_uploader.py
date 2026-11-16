"""Integration tests for countly_dsym_uploader.sh.

Every test runs the script the way Xcode or a CI job does, against real dSYM bundles
built with clang and dsymutil, and checks what a local HTTP server received.

Run from the repository root (macOS with Xcode and its platform SDKs):

    python3 -m unittest discover -s Tests/DsymUploaderTests -v
"""

import io
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
import zipfile
from email.parser import BytesParser
from email.policy import default as default_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "countly_dsym_uploader.sh"
UPLOAD_PATH = "/i/crash_symbols/upload_symbol"
APP_KEY = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
SUCCESS_BODY = b'{"result":"Success"}'
IOS_DEVICE = ("iphoneos", ["-target", "arm64-apple-ios15.0"])

XCODE_VARIABLES = (
    "PLATFORM_NAME", "IS_MACCATALYST", "DWARF_DSYM_FOLDER_PATH", "DWARF_DSYM_FILE_NAME",
    "DEBUG_INFORMATION_FORMAT", "DEPLOYMENT_POSTPROCESSING", "ENABLE_USER_SCRIPT_SANDBOXING",
    "COUNTLY_DSYM_PLATFORM", "COUNTLY_DSYM_STRICT",
)
PROXY_VARIABLES = ("http_proxy", "https_proxy", "all_proxy")


class CapturedUpload:
    """One request the capture server received, with its multipart parts decoded."""

    def __init__(self, path, query, fields, files):
        """Keeps the decoded parts of one request."""
        self.path = path
        self.query = query
        self.fields = fields
        self.files = files

    def zip_entries(self):
        """Names of the files inside the uploaded `symbols` zip."""
        _, data = self.files["symbols"]
        return sorted(name for name in zipfile.ZipFile(io.BytesIO(data)).namelist() if not name.endswith("/"))


class CaptureServer:
    """A local HTTP server that records every request and answers with a set reply."""

    def __init__(self):
        """Starts listening on a free local port."""
        self.uploads = []
        self.status = 200
        self.body = SUCCESS_BODY
        self._lock = threading.Lock()
        server = self

        class Handler(BaseHTTPRequestHandler):
            """Answers every upload the capture server receives."""

            def do_POST(self):
                """Records a multipart upload and sends the configured reply."""
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length)
                parsed = urllib.parse.urlparse(self.path)
                fields, files = parse_multipart(self.headers.get("Content-Type", ""), body)
                with server._lock:
                    server.uploads.append(
                        CapturedUpload(parsed.path, urllib.parse.parse_qs(parsed.query), fields, files))
                    status, reply = server.status, server.body
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *args):
                """Keeps the test output free of access logs."""

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def reply_with(self, status, body):
        """Sets the status and body every following request receives."""
        with self._lock:
            self.status, self.body = status, body

    def reset(self):
        """Forgets recorded uploads and goes back to the success reply."""
        with self._lock:
            self.uploads = []
            self.status, self.body = 200, SUCCESS_BODY

    def close(self):
        """Stops the server."""
        self._httpd.shutdown()
        self._httpd.server_close()


def parse_multipart(content_type, body):
    """Splits a multipart/form-data body into text fields and (filename, bytes) files."""
    fields, files = {}, {}
    if not content_type.startswith("multipart/form-data"):
        return fields, files
    message = BytesParser(policy=default_policy).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body)
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        payload = part.get_payload(decode=True) or b""
        if part.get_filename() is None:
            fields[name] = payload.decode("utf-8")
        else:
            files[name] = (part.get_filename(), payload)
    return fields, files


def run(command, cwd=None):
    """Runs a build tool and fails loudly with its output when it fails."""
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("%s failed:\n%s%s" % (command[0:4], result.stdout, result.stderr))
    return result.stdout


def sdk_installed(sdk):
    """Whether Xcode has the platform SDK a fixture is built against."""
    return subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-path"], capture_output=True).returncode == 0


def build_dsym(folder, name, bundle_name, variant, sdk="macosx", flags=("-arch", "arm64")):
    """Compiles a small program for an SDK and writes its dSYM as `folder/bundle_name`.

    `variant` changes the code, so that every fixture gets build UUIDs of its own.
    """
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / ("%s.c" % name)
    source.write_text(
        "int fixture_value(void) { return %d; }\n"
        "int main(void) { return fixture_value(); }\n" % variant)
    obj = folder / ("%s.o" % name)
    binary = folder / name
    run(["xcrun", "--sdk", sdk, "clang", "-g", "-c", *flags, str(source), "-o", str(obj)])
    run(["xcrun", "--sdk", sdk, "clang", *flags, str(obj), "-o", str(binary)])
    dsym = folder / bundle_name
    run(["xcrun", "dsymutil", str(binary), "-o", str(dsym)])
    plist = dsym / "Contents" / "Info.plist"
    run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleShortVersionString 2.3.4", str(plist)])
    run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleVersion 567", str(plist)])
    return dsym


def build_uuids(dsym):
    """The build UUIDs dwarfdump reports for a dSYM, one per architecture."""
    output = run(["xcrun", "dwarfdump", "--uuid", str(dsym)])
    return sorted(line.split()[1] for line in output.splitlines() if line.startswith("UUID:"))


def closed_port():
    """A local port nothing listens on."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class DsymUploaderTests(unittest.TestCase):
    """End to end behaviour of countly_dsym_uploader.sh."""

    @classmethod
    def setUpClass(cls):
        """Builds the dSYM fixtures once and starts the capture server."""
        cls.work = Path(tempfile.mkdtemp(prefix="countly-dsym-tests-"))
        products = cls.work / "products"
        sdk, flags = IOS_DEVICE
        cls.app_dsym = build_dsym(products, "Fixture", "Fixture.app.dSYM", 1, sdk, flags)
        cls.framework_dsym = build_dsym(products, "Helper", "Helper.framework.dSYM", 3, sdk, flags)
        build_dsym(products / "nested", "Nested", "Nested.app.dSYM", 4, sdk, flags)
        (products / "notes.txt").write_text("not a dSYM")
        cls.universal_dsym = build_dsym(
            cls.work / "universal", "Universal", "Universal.app.dSYM", 2,
            flags=("-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0"))
        cls.products = products
        cls.server = CaptureServer()

    @classmethod
    def tearDownClass(cls):
        """Stops the server and removes the fixtures."""
        cls.server.close()
        shutil.rmtree(cls.work, ignore_errors=True)

    def setUp(self):
        """Every test starts with no recorded uploads and a success reply."""
        self.server.reset()

    def run_script(self, *args, env=None):
        """Runs the script through `sh`, as an Xcode Run Script phase does, past any proxy."""
        environment = {key: value for key, value in os.environ.items()
                       if key not in XCODE_VARIABLES and key.lower() not in PROXY_VARIABLES}
        environment["NO_PROXY"] = environment["no_proxy"] = "127.0.0.1,localhost"
        environment.update(env or {})
        return subprocess.run(["sh", str(SCRIPT), *args], env=environment,
                              capture_output=True, text=True, timeout=300)

    def xcode_environment(self, dsym=None, **overrides):
        """The variables Xcode gives a Run Script phase for a target's dSYM."""
        dsym = dsym or self.app_dsym
        environment = {
            "DWARF_DSYM_FOLDER_PATH": str(dsym.parent),
            "DWARF_DSYM_FILE_NAME": dsym.name,
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        }
        environment.update(overrides)
        return environment

    def copy_of(self, dsym, folder):
        """A copy of a fixture dSYM that a test may change."""
        copy = self.work / folder / dsym.name
        shutil.copytree(dsym, copy)
        return copy

    def assert_problem(self, result, fragment):
        """The run reported a warning containing `fragment`, and still exited 0."""
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        warnings = [line for line in result.stdout.splitlines() if line.startswith("warning: [Countly]")]
        self.assertTrue(any(fragment in line for line in warnings),
                        "no warning containing %r in:\n%s" % (fragment, result.stdout))

    def test_uploads_a_dsym_with_its_uuid_platform_and_symbol_files(self):
        """A dSYM goes up with its UUID, platform and version note, the key out of the URL."""

        result = self.run_script(self.server.url, APP_KEY, str(self.app_dsym))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.server.uploads), 1)
        upload = self.server.uploads[0]
        self.assertEqual(upload.path, UPLOAD_PATH)
        self.assertEqual(upload.query, {}, "the app key must not travel in the URL")
        self.assertEqual(upload.fields, {
            "platform": "ios",
            "app_key": APP_KEY,
            "build": ",".join(build_uuids(self.app_dsym)),
            "note": "2.3.4 (567)",
        })
        filename, _ = upload.files["symbols"]
        self.assertEqual(filename, "Fixture.app.dSYM.zip")
        self.assertEqual(upload.zip_entries(), [
            "Fixture.app.dSYM/Contents/Info.plist",
            "Fixture.app.dSYM/Contents/Resources/DWARF/Fixture",
        ])
        self.assertIn("Uploaded 1 of 1 dSYM files.", result.stdout)
        self.assertNotIn("warning:", result.stdout)
        self.assertNotIn(APP_KEY, result.stdout + result.stderr)
        self.assertIn("a1b2****", result.stdout)

    def test_hidden_files_and_relocations_stay_out_of_the_zip(self):
        """The server reads the DWARF folder's only file, so nothing else from it is sent."""

        dsym = self.copy_of(self.app_dsym, "extras")
        (dsym / "Contents" / "Resources" / "DWARF" / ".DS_Store").write_bytes(b"finder")
        relocations = dsym / "Contents" / "Resources" / "Relocations" / "aarch64"
        relocations.mkdir(parents=True, exist_ok=True)
        (relocations / "Fixture.yml").write_text("---\n")

        result = self.run_script(self.server.url, APP_KEY, str(dsym))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.server.uploads[0].zip_entries(), [
            "Fixture.app.dSYM/Contents/Info.plist",
            "Fixture.app.dSYM/Contents/Resources/DWARF/Fixture",
        ])

    def test_a_dsym_without_an_info_plist_uploads_with_an_empty_note(self):
        """Some tools write dSYMs without an Info.plist; the DWARF file alone is enough."""

        dsym = self.copy_of(self.app_dsym, "no-plist")
        (dsym / "Contents" / "Info.plist").unlink()

        result = self.run_script(self.server.url, APP_KEY, str(dsym))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        upload = self.server.uploads[0]
        self.assertEqual(upload.fields["note"], "")
        self.assertEqual(upload.zip_entries(), ["Fixture.app.dSYM/Contents/Resources/DWARF/Fixture"])
        self.assertIn("Uploaded 1 of 1 dSYM files.", result.stdout)

    def test_universal_dsym_reports_every_architecture_uuid(self):
        """A universal dSYM is uploaded once with the UUID of every architecture."""

        result = self.run_script(self.server.url, APP_KEY, str(self.universal_dsym))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.server.uploads), 1)
        uploaded = sorted(self.server.uploads[0].fields["build"].split(","))
        self.assertEqual(len(uploaded), 2)
        self.assertEqual(uploaded, build_uuids(self.universal_dsym))
        self.assertEqual(self.server.uploads[0].fields["platform"], "macos")

    def test_folder_uploads_every_dsym_in_it_once_and_nothing_else(self):
        """A folder such as an archive's dSYMs uploads each dSYM directly inside it, once."""

        result = self.run_script(self.server.url, APP_KEY, str(self.products) + "/")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uploaded = sorted((upload.files["symbols"][0], upload.fields["build"])
                          for upload in self.server.uploads)
        self.assertEqual(uploaded, [
            ("Fixture.app.dSYM.zip", ",".join(build_uuids(self.app_dsym))),
            ("Helper.framework.dSYM.zip", ",".join(build_uuids(self.framework_dsym))),
        ])
        self.assertIn("Uploaded 2 of 2 dSYM files.", result.stdout)

    def test_a_symlinked_folder_is_followed(self):
        """A folder given through a symbolic link is searched like the folder itself."""

        link = self.work / "linked-products"
        if not link.exists():
            link.symlink_to(self.products)

        result = self.run_script(self.server.url, APP_KEY, str(link) + "/")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.server.uploads), 2)

    def test_each_dsym_goes_up_under_the_platform_it_was_built_for(self):
        """The platform comes from each dSYM, so a folder mixing platforms tags each one right."""

        cases = [
            ("iOS", "iphoneos", ["-target", "arm64-apple-ios15.0"], "ios"),
            ("iOSSimulator", "iphonesimulator", ["-target", "arm64-apple-ios15.0-simulator"], "ios"),
            ("Catalyst", "macosx", ["-target", "arm64-apple-ios15.0-macabi"], "ios"),
            ("macOS", "macosx", ["-target", "arm64-apple-macos12.0"], "macos"),
            ("tvOS", "appletvos", ["-target", "arm64-apple-tvos15.0"], "tvos"),
            ("watchOS", "watchos", ["-target", "arm64_32-apple-watchos9.0"], "watchos"),
            ("visionOS", "xros", ["-target", "arm64-apple-xros1.0"], "ios"),
        ]
        folder = self.work / "platforms"
        expected = {}
        for variant, (name, sdk, flags, platform) in enumerate(cases, start=10):
            if not sdk_installed(sdk):
                continue
            build_dsym(folder, name, "%s.app.dSYM" % name, variant, sdk, flags)
            expected["%s.app.dSYM.zip" % name] = platform
        self.assertIn("iOS.app.dSYM.zip", expected, "the iOS SDK is needed for this test")

        result = self.run_script(self.server.url, APP_KEY, str(folder))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uploaded = {upload.files["symbols"][0]: upload.fields["platform"] for upload in self.server.uploads}
        self.assertEqual(uploaded, expected)

        self.server.reset()
        result = self.run_script(self.server.url, APP_KEY, str(folder), env={"COUNTLY_DSYM_PLATFORM": "tvos"})
        self.assertEqual({upload.fields["platform"] for upload in self.server.uploads}, {"tvos"},
                         "COUNTLY_DSYM_PLATFORM overrides what the dSYMs say")

    def test_invalid_platform_override_uploads_nothing(self):
        """An unknown platform override uploads nothing, warns, and fails only in strict mode."""

        environment = {"COUNTLY_DSYM_PLATFORM": "visionos"}
        result = self.run_script(self.server.url, APP_KEY, str(self.app_dsym), env=environment)

        self.assert_problem(result, "COUNTLY_DSYM_PLATFORM must be ios, macos, tvos or watchos")
        self.assertEqual(self.server.uploads, [])

        environment["COUNTLY_DSYM_STRICT"] = "1"
        strict = self.run_script(self.server.url, APP_KEY, str(self.app_dsym), env=environment)
        self.assertEqual(strict.returncode, 1)
        self.assertIn("error: [Countly] COUNTLY_DSYM_PLATFORM must be", strict.stdout)
        self.assertEqual(self.server.uploads, [])

    def test_xcode_mode_uploads_the_targets_dsym(self):
        """Run from Xcode without a path, the script uploads the dSYM the build variables name."""

        result = self.run_script(self.server.url, APP_KEY, env=self.xcode_environment())

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([upload.files["symbols"][0] for upload in self.server.uploads], ["Fixture.app.dSYM.zip"])
        self.assertEqual(self.server.uploads[0].fields["build"], ",".join(build_uuids(self.app_dsym)))

    def test_a_debug_build_without_a_dsym_is_skipped_quietly(self):
        """A configuration that produces no dSYM, such as Debug, is skipped without a warning."""

        environment = self.xcode_environment(
            DEBUG_INFORMATION_FORMAT="dwarf",
            DWARF_DSYM_FOLDER_PATH=str(self.work / "Debug-iphoneos"))
        result = self.run_script(self.server.url, APP_KEY, env=environment)

        self.assertEqual(result.returncode, 0)
        self.assertIn("produces no dSYM", result.stdout)
        self.assertNotIn("warning:", result.stdout)
        self.assertEqual(self.server.uploads, [])

    def test_an_install_build_without_a_dsym_is_reported(self):
        """An archive ships, so a configuration without a dSYM there warns, and fails in strict mode."""

        environment = self.xcode_environment(
            DEBUG_INFORMATION_FORMAT="dwarf", DEPLOYMENT_POSTPROCESSING="YES",
            DWARF_DSYM_FOLDER_PATH=str(self.work / "Release-iphoneos"))
        result = self.run_script(self.server.url, APP_KEY, env=environment)

        self.assert_problem(result, "produces no dSYM")
        self.assertEqual(self.server.uploads, [])

        environment["COUNTLY_DSYM_STRICT"] = "1"
        strict = self.run_script(self.server.url, APP_KEY, env=environment)
        self.assertEqual(strict.returncode, 1)
        self.assertIn("error: [Countly] This build configuration produces no dSYM", strict.stdout)

    def test_missing_xcode_dsym_points_at_the_input_files(self):
        """A dSYM Xcode has not written yet, as without Input Files, is reported with the fix."""

        environment = self.xcode_environment(DWARF_DSYM_FOLDER_PATH=str(self.work / "missing"))
        result = self.run_script(self.server.url, APP_KEY, env=environment)

        self.assert_problem(result, "The dSYM Xcode should have produced is missing")
        self.assertIn("to the Input Files of this Run Script phase", result.stdout)
        self.assertEqual(self.server.uploads, [])

    @unittest.skipIf(os.geteuid() == 0, "root reads files whatever their permissions")
    def test_unreadable_dsym_is_never_uploaded_in_part(self):
        """A dSYM with an unreadable file, as under User Script Sandboxing, is reported and never uploaded in part."""

        dsym = self.copy_of(self.app_dsym, "unreadable")
        plist = dsym / "Contents" / "Info.plist"
        plist.chmod(0)
        self.addCleanup(plist.chmod, 0o644)
        environment = self.xcode_environment(dsym=dsym)

        result = self.run_script(self.server.url, APP_KEY, env=environment)

        self.assert_problem(result, "Could not read every file of Fixture.app.dSYM")
        self.assertIn("Add the dSYM folder, its Contents/Info.plist", result.stdout)
        self.assertIn("Uploaded 0 of 1 dSYM files.", result.stdout)
        self.assertEqual(self.server.uploads, [])

        environment["COUNTLY_DSYM_STRICT"] = "1"
        strict = self.run_script(self.server.url, APP_KEY, env=environment)
        self.assertEqual(strict.returncode, 1)
        self.assertIn("error: [Countly] Could not read every file", strict.stdout)
        self.assertEqual(self.server.uploads, [])

    def test_server_rejection_is_reported_with_its_status_size_and_reply(self):
        """A rejected upload is reported with the server's status and reply, and the zip size."""

        self.server.reply_with(400, json.dumps({"result": "Missing platform"}).encode())
        result = self.run_script(self.server.url, APP_KEY, str(self.app_dsym))

        self.assert_problem(result, "HTTP status: 400")
        self.assertRegex(result.stdout, r"The server did not accept Fixture\.app\.dSYM \(\d+ KB\)")
        self.assertIn("Missing platform", result.stdout)
        self.assertIn("Uploaded 0 of 1 dSYM files.", result.stdout)
        self.assertEqual(len(self.server.uploads), 1)

        self.server.reset()
        self.server.reply_with(401, b'{"result":"App does not exist"}')
        strict = self.run_script(self.server.url, APP_KEY, str(self.app_dsym),
                                 env={"COUNTLY_DSYM_STRICT": "1"})
        self.assertEqual(strict.returncode, 1)
        self.assertIn("error: [Countly] The server did not accept Fixture.app.dSYM", strict.stdout)
        self.assertIn("HTTP status: 401", strict.stdout)

    def test_a_failed_upload_is_not_retried(self):
        """The server stores every request it accepts, so a failed upload is sent once."""

        self.server.reply_with(503, b"busy")
        result = self.run_script(self.server.url, APP_KEY, str(self.app_dsym))

        self.assert_problem(result, "HTTP status: 503")
        self.assertEqual(len(self.server.uploads), 1)

    def test_a_refused_app_key_stops_the_remaining_uploads(self):
        """A key the server refuses would be refused for every dSYM, so the rest are skipped."""

        self.server.reply_with(401, b'{"result":"App does not exist"}')
        result = self.run_script(self.server.url, APP_KEY, str(self.products))

        self.assertEqual(len(self.server.uploads), 1)
        self.assert_problem(result, "Skipped the other 1 dSYM files, because the server refused the app key.")
        self.assertIn("Uploaded 0 of 2 dSYM files.", result.stdout)

    def test_unreachable_server_is_reported_without_hanging(self):
        """An unreachable server is reported promptly, once, instead of holding the build."""

        started = time.monotonic()
        result = self.run_script("http://127.0.0.1:%d" % closed_port(), APP_KEY, str(self.products))

        self.assertLess(time.monotonic() - started, 60)
        self.assert_problem(result, "Uploading Fixture.app.dSYM")
        self.assertEqual(result.stdout.count("failed: curl"), 1)
        self.assert_problem(result, "Skipped the other 1 dSYM files, because the server could not be reached.")
        self.assertIn("Uploaded 0 of 2 dSYM files.", result.stdout)

    def test_success_replies_of_old_and_new_servers_both_count(self):
        """Both success replies the server has used count as uploaded, and a non-Countly 200 does not."""

        cases = [
            (200, b'{"result":"Success"}', True),
            (200, b'{"message":"Success","_id":"6afad2146b1e8a967065de82"}', True),
            (200, b"<html><body>Sign in to continue</body></html>", False),
            (200, b"", False),
        ]
        for status, body, accepted in cases:
            with self.subTest(body=body):
                self.server.reply_with(status, body)
                result = self.run_script(self.server.url, APP_KEY, str(self.app_dsym))

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(self.server.uploads), 1)
                if accepted:
                    self.assertIn("Uploaded 1 of 1 dSYM files.", result.stdout)
                    self.assertNotIn("warning:", result.stdout)
                else:
                    self.assert_problem(result, "The server did not accept Fixture.app.dSYM")
                    self.assertIn("HTTP status: 200", result.stdout)
                self.server.reset()

    def test_strict_mode_passes_when_every_upload_succeeds(self):
        """Strict mode fails only on a problem, so a clean run exits 0."""

        result = self.run_script(self.server.url, APP_KEY, str(self.products), env={"COUNTLY_DSYM_STRICT": "1"})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Uploaded 2 of 2 dSYM files.", result.stdout)
        self.assertNotIn("error:", result.stdout)

    def test_arguments_are_validated_before_anything_is_uploaded(self):
        """Missing or malformed arguments are reported before anything is uploaded."""

        cases = [
            ((), "The server URL and the app key are both required"),
            ((self.server.url,), "The server URL and the app key are both required"),
            (("countly.example.com", APP_KEY, str(self.app_dsym)), "must start with http:// or https://"),
            ((self.server.url, APP_KEY, str(self.work / "nothing-here")), "No dSYM was found"),
            ((self.server.url, APP_KEY, str(self.work / "Nothing.app.dSYM")), "No dSYM was found"),
            ((self.server.url, APP_KEY), "the Xcode build variables that locate one are not set"),
        ]
        for args, fragment in cases:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assert_problem(result, fragment)

                strict = self.run_script(*args, env={"COUNTLY_DSYM_STRICT": "1"})
                self.assertEqual(strict.returncode, 1)
                self.assertIn("error: [Countly]", strict.stdout)
        self.assertEqual(self.server.uploads, [])

    def test_server_url_keeps_its_path_and_loses_trailing_slashes(self):
        """A server URL with a path prefix and trailing slashes reaches the right endpoint."""

        result = self.run_script(self.server.url + "/countly//", APP_KEY, str(self.app_dsym))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([upload.path for upload in self.server.uploads], ["/countly" + UPLOAD_PATH])


if __name__ == "__main__":
    unittest.main()
