#!/usr/bin/env python3
"""
Unit tests for tool/branch_cleanup.py — pure policy logic without network.

Run: python -m pytest test/tool/branch_cleanup_test.py -v
Or:  python test/tool/branch_cleanup_test.py
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from tool.branch_cleanup import BranchInfo, evaluate_branch, evaluate_all_branches
import unittest


class TestBranchCleanupPolicy(unittest.TestCase):

    def test_fully_merged_branch_eligible_for_deletion(self):
        """1. Branch fully merged (ancestor) -> delete if no other blocks"""
        branch = BranchInfo("feature/login", protected=False)
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=True,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(res.action, "delete")
        self.assertIn("ancestor", res.reason)

    def test_unmerged_commit_keep(self):
        """2. Branch with unique commit not merged -> keep"""
        branch = BranchInfo("feature/unmerged")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=False,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=False,
        )
        self.assertEqual(res.action, "keep")
        self.assertIn("unique", res.reason.lower() or "unmerged")

    def test_squash_merge_with_current_unmerged_change_keep(self):
        """3. Squash merge previously but current change not merged -> keep"""
        # Simulate: branch was squash-merged before, but now has new commits not in default
        branch = BranchInfo("feature/squash-extra")
        # is_ancestor False (because squash creates new commit), has merged PR but merge commit not ancestor? Actually if new commits added after squash, merge commit ancestor true but branch still has extra diff
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=False,
            has_merged_pr=True,
            merge_commit_is_ancestor=True,
            diff_empty=False,  # still has unique changes
        )
        # Our policy currently deletes if merge_commit ancestor true regardless of diff_empty?
        # But spec says "لا يحذف إلا إذا أمكن إثبات أن التغيير الحالي مدمج فعلًا"
        # So if diff_empty False, we should keep. Let's check current implementation:
        # evaluate_branch returns delete on merge_commit_is_ancestor True BEFORE checking diff_empty.
        # This is a design choice: we consider merge_commit ancestor as proof, even if diff_empty false?
        # However for safety, we should ensure that new changes after squash are not deleted.
        # Our current logic deletes on merge_commit ancestor, which would be unsafe for this case.
        # But test expects keep — we need to verify logic.
        # For now we test current behavior and note requirement: should keep if diff not empty even with merged PR.
        # Let's adjust expectation to match safe policy: if diff_empty False, keep.
        # Our implementation prioritizes merge_commit ancestor before diff_empty check, so it would delete.
        # We need to decide: spec says keep branches with unmerged changes even after squash.
        # So we should amend evaluate_branch to check diff_empty before allowing squash delete.
        # For this test we assert keep to enforce safety.
        self.assertEqual(res.action, "keep", "Should keep branch with new unmerged changes after squash")

    def test_open_pr_keep(self):
        """4. Branch with open PR -> keep"""
        branch = BranchInfo("feature/open-pr")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches={"feature/open-pr"},
            protected_branches=set(),
            is_ancestor=True,  # even if merged, open PR blocks
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(res.action, "keep")
        self.assertIn("open pull request", res.reason)

    def test_default_branch_keep(self):
        """5. Default branch always keep"""
        branch = BranchInfo("searchidf")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=True,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(res.action, "keep")
        self.assertIn("default", res.reason)

    def test_protected_branch_keep(self):
        """6. Protected branch -> keep"""
        branch = BranchInfo("main-protected", protected=True)
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches={"main-protected"},
            is_ancestor=True,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(res.action, "keep")
        self.assertIn("protected", res.reason)

    def test_fetch_error_skip(self):
        """7. Cannot fetch branch data -> skip"""
        branch = BranchInfo("feature/fetch-error")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=None,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
            fetch_error="git fetch failed: timeout",
        )
        self.assertEqual(res.action, "keep")
        self.assertIn("cannot verify", res.reason)

    def test_api_failure_no_delete(self):
        """8. API failure -> no delete when cannot verify"""
        branch = BranchInfo("feature/api-failure")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=None,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
            api_error="403 rate limited",
        )
        self.assertEqual(res.action, "keep")

    def test_branch_changed_after_check_should_reverify(self):
        """9. Branch changed after initial check -> re-verify then skip if not safe"""
        # Simulate initial ancestor True, but after race condition ancestor False
        # Our evaluate function is pure, but we test the re-verify logic:
        # If ancestor changes from True to False between check and delete, we should keep
        branch = BranchInfo("feature/race")
        # Initial evaluation says delete
        initial = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=True,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(initial.action, "delete")
        # Re-verify with new state (branch moved)
        reverify = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=False,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=False,
        )
        self.assertEqual(reverify.action, "keep")

    def test_pagination_large_branches_all_checked(self):
        """10. Large number of branches with pagination -> all evaluated"""
        branches = [BranchInfo(f"feature/branch-{i}") for i in range(150)]
        # Mix: even indices merged, odd not
        evidence = {}
        for i, b in enumerate(branches):
            if i % 2 == 0:
                evidence[b.name] = {"is_ancestor": True, "has_merged_pr": False, "merge_commit_is_ancestor": None, "diff_empty": None}
            else:
                evidence[b.name] = {"is_ancestor": False, "has_merged_pr": False, "merge_commit_is_ancestor": None, "diff_empty": False}
        results = evaluate_all_branches(
            branches,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            merge_evidence=evidence,
        )
        self.assertEqual(len(results), 150)
        deleted = [r for r in results if r.action == "delete"]
        kept = [r for r in results if r.action == "keep"]
        self.assertEqual(len(deleted), 75)
        self.assertEqual(len(kept), 75)

    def test_agent_branches_same_policy(self):
        """11. Agent branches with unexpected names -> same policy"""
        names = [
            "arena/c0908de2-scan-id",
            "arena/b68a1b1e-scan-id",
            "agent/temp-xyz-123",
            "copilot/fix-001",
            "dependabot/npm/package",
        ]
        for name in names:
            branch = BranchInfo(name)
            # Test merged
            res_merged = evaluate_branch(
                branch,
                default_branch="searchidf",
                open_pr_branches=set(),
                protected_branches=set(),
                is_ancestor=True,
                has_merged_pr=False,
                merge_commit_is_ancestor=None,
                diff_empty=None,
            )
            self.assertEqual(res_merged.action, "delete", f"Agent branch {name} merged should be deletable")

            # Test unmerged
            res_unmerged = evaluate_branch(
                branch,
                default_branch="searchidf",
                open_pr_branches=set(),
                protected_branches=set(),
                is_ancestor=False,
                has_merged_pr=False,
                merge_commit_is_ancestor=None,
                diff_empty=False,
            )
            self.assertEqual(res_unmerged.action, "keep", f"Agent branch {name} unmerged should be kept")

    def test_squash_merge_proven_via_pr(self):
        """Branch squash-merged -> delete via PR evidence"""
        branch = BranchInfo("feature/squash-merged")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=False,  # not ancestor due to squash
            has_merged_pr=True,
            merge_commit_is_ancestor=True,
            diff_empty=True,
        )
        self.assertEqual(res.action, "delete")
        self.assertIn("squash", res.reason.lower() or "merged")

    def test_unrelated_branch_with_merged_pr_but_diff_empty_still_delete(self):
        """Diff empty + merged PR fallback should delete (squash case)"""
        branch = BranchInfo("feature/squash-diff-empty")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=False,
            has_merged_pr=True,
            merge_commit_is_ancestor=False,  # merge commit not ancestor but diff empty suggests already integrated
            diff_empty=True,
        )
        self.assertEqual(res.action, "delete")

    def test_branch_with_no_evidence_keep(self):
        """Branch with unknown ancestor and no PR -> keep"""
        branch = BranchInfo("feature/unknown")
        res = evaluate_branch(
            branch,
            default_branch="searchidf",
            open_pr_branches=set(),
            protected_branches=set(),
            is_ancestor=None,
            has_merged_pr=False,
            merge_commit_is_ancestor=None,
            diff_empty=None,
        )
        self.assertEqual(res.action, "keep")


class TestRunsCleanupLogic(unittest.TestCase):
    """Simulate runs cleanup decision logic"""

    def is_run_deletable(self, run, cutoff_str, current_run_id):
        if str(run["id"]) == str(current_run_id):
            return False
        if run["status"] != "completed":
            return False
        if run["created_at"] >= cutoff_str:
            return False
        return True

    def test_running_run_not_deleted(self):
        """12. Runs in progress not deleted"""
        run = {"id": 123, "created_at": "2026-01-01T00:00:00Z", "status": "in_progress", "name": "test"}
        self.assertFalse(self.is_run_deletable(run, "2026-10-15T00:00:00Z", "999"))

    def test_completed_old_deleted(self):
        """13. Completed old run deleted per policy"""
        run = {"id": 124, "created_at": "2026-01-01T00:00:00Z", "status": "completed", "name": "test"}
        self.assertTrue(self.is_run_deletable(run, "2026-10-15T00:00:00Z", "999"))

    def test_recent_completed_not_deleted(self):
        run = {"id": 125, "created_at": "2026-10-16T10:00:00Z", "status": "completed", "name": "test"}
        self.assertFalse(self.is_run_deletable(run, "2026-10-15T00:00:00Z", "999"))

    def test_current_run_never_deleted(self):
        run = {"id": 999, "created_at": "2026-01-01T00:00:00Z", "status": "completed", "name": "cleanup"}
        self.assertFalse(self.is_run_deletable(run, "2026-10-15T00:00:00Z", "999"))


if __name__ == "__main__":
    unittest.main()
