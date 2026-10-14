#!/usr/bin/env python3
"""Tests for clean inputs, relocation, configuration, and fail-fast guards."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("create_project", Path(__file__).with_name("create_project.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


class ProjectTest(unittest.TestCase):
    def args(self, out, **kwargs):
        values = dict(cpu_mhz=250., jobs=2, profile="soc", stage="generate", manifest=None,
                      config="configs/defconfig", output=out, with_pll=True, allow_version_mismatch=False,
                      irom_coe=None, dram_coe=None)
        values.update(kwargs)
        return argparse.Namespace(**values)

    def test_clean_snapshot_and_relocation(self):
        with tempfile.TemporaryDirectory(prefix="ares-vivado ") as temp:
            out = gen.prepare(self.args(Path(temp) / "build with spaces"))
            root = ET.parse(out / "ares.xpr").getroot()
            self.assertFalse(root.findall(".//File"))
            self.assertEqual({r.get("Id") for r in root.findall("Runs/Run")},
                             {"synth_1", "impl_1", "impl_1_copy_1", "impl_1_copy_2"})
            self.assertTrue(all("IncrementalCheckpoint" not in r.attrib for r in root.findall("Runs/Run")))
            inputs = json.loads((out / "inputs.json").read_text())
            self.assertEqual(inputs["config"]["MUL_LATENCY"], 3)
            self.assertEqual(inputs["config"]["LINE_BYTES"], 32)
            self.assertFalse(any("/npc/" in p or "/miniTensor/" in p or "/test/" in p for p in inputs["inputs"]))
            moved = out.rename(Path(temp) / "moved project")
            script = (moved / "generate.tcl").read_text()
            self.assertNotIn(str(out), script)
            # Evaluate generated variable assignments with real Tcl, without Vivado.
            body = script.rsplit("source ", 1)[0]
            result = subprocess.run(["tclsh"], input="set ares_build_dir " + gen.tcl(moved) + "\n" +
                "\n".join(body.splitlines()[1:]) + '\nputs [file exists $ares_project]\nputs [llength $ares_sources]\n',
                text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.splitlines()[0], "1")
            self.assertGreater(int(result.stdout.splitlines()[1]), 30)

    def test_literal_tcl_word(self):
        value = 'space $env(HOME) [exec echo oops] "quotes" {braces} \\ slash\nnewline'
        result = subprocess.run(["tclsh"], input="set x " + gen.tcl(value) +
            "\nputs [binary encode hex $x]\n", text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), value.encode().hex())

    def test_invalid_clock_and_existing_output(self):
        with tempfile.TemporaryDirectory() as temp:
            for mhz in [200, -1, float("nan"), float("inf")]:
                with self.assertRaises(ValueError): gen.prepare(self.args(Path(temp)/"bad", cpu_mhz=mhz))
            out = Path(temp)/"existing"; out.mkdir(); (out/"keep").write_text("keep")
            with self.assertRaises(ValueError): gen.prepare(self.args(out))
            self.assertEqual((out/"keep").read_text(), "keep")

    def test_vendor_path_restriction_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/"illegal $ [path]"
            with self.assertRaises(ValueError): gen.prepare(self.args(out))
            self.assertFalse(out.exists())

    def test_board_and_route_guards(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/"project"
            with self.assertRaises(ValueError): gen.prepare(self.args(out, profile="board"))
            with self.assertRaises(ValueError): gen.prepare(self.args(out, stage="route"))
            self.assertFalse(out.exists())

    def test_missing_or_invalid_image_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/"project"
            with self.assertRaises(ValueError): gen.prepare(self.args(out, irom_coe=str(Path(temp)/"missing.coe")))
            self.assertFalse(out.exists())
            image = Path(temp)/"bad.coe"
            image.write_text("memory_initialization_radix=16; memory_initialization_vector=10000000000000000;")
            with self.assertRaises(ValueError): gen.prepare(self.args(out, irom_coe=str(image)))
            self.assertFalse(out.exists())

    def test_valid_image_and_config_override(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp)/"config"; config.write_text("CONFIG_MUL_LATENCY=2\nCONFIG_LINE_BYTES_64=y\n")
            image = Path(temp)/"image.coe"
            image.write_text("memory_initialization_radix=16; memory_initialization_vector=0000001300000013;")
            out = gen.prepare(self.args(Path(temp)/"project", config=str(config), irom_coe=str(image)))
            inp = json.loads((out/"inputs.json").read_text())
            self.assertEqual(inp["config"]["LINE_BYTES"], 64)
            self.assertEqual(inp["config"]["MUL_LATENCY"], 2)
            self.assertTrue(any(p.endswith("image.coe") for p in inp["inputs"]))


if __name__ == "__main__":
    unittest.main()
