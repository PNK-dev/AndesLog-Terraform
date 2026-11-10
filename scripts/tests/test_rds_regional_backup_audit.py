import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("rds_regional_backup_audit", Path(__file__).resolve().parents[1] / "rds_regional_backup_audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

ACCOUNT = "123456789012"
SOURCE = f"arn:aws:rds:us-east-1:{ACCOUNT}:db:andeslog-lab-postgres"
BACKUP = f"arn:aws:rds:us-west-2:{ACCOUNT}:auto-backup:ab-TEST123"
DBI = "db-TEST123"


class FakeAws:
    def __init__(self, record=None):
        self.record = record
        self.calls = []
        self.account = ACCOUNT
        self.before_describe = None

    def __call__(self, args):
        self.calls.append(args)
        if args[:2] == ["sts", "get-caller-identity"]:
            return {"Account": self.account}
        if args[:2] == ["rds", "describe-db-instance-automated-backups"]:
            if self.before_describe:
                self.before_describe(self)
            return {"DBInstanceAutomatedBackups": [] if self.record is None else [self.record]}
        if args[:2] == ["rds", "delete-db-instance-automated-backup"]:
            self.record = None
            return {}
        raise AssertionError("unexpected AWS call")


def record(**changes):
    value = {"DBInstanceAutomatedBackupsArn": BACKUP, "DBInstanceArn": SOURCE,
             "DbiResourceId": DBI, "Status": "retained", "BackupRetentionPeriod": 7}
    value.update(changes)
    return value


def invoke(fake, *, execute=False):
    tick = [0.0]
    return audit.inspect_or_delete(ACCOUNT, BACKUP, SOURCE, DBI, execute=execute, query=fake,
                                   clock=lambda: tick[0], sleep=lambda seconds: tick.__setitem__(0, tick[0] + seconds))


def test_preview_is_read_only_and_reports_exact_record():
    fake = FakeAws(record())
    result, code = invoke(fake)
    assert code == 0 and result["mode"] == "preview" and result["status"] == "retained"
    assert all("delete-db-instance-automated-backup" not in call for call in fake.calls)


def test_deletes_only_validated_retained_backup_and_checks_twice():
    fake = FakeAws(record())
    result, code = invoke(fake, execute=True)
    assert code == 0 and result["status"] == "not_found_after_delete"
    deletes = [call for call in fake.calls if "delete-db-instance-automated-backup" in call]
    assert len(deletes) == 1 and deletes[0][-1] == BACKUP
    assert len([call for call in fake.calls if "describe-db-instance-automated-backups" in call]) == 4


@pytest.mark.parametrize("changes", [{"Status": "replicating"}, {"Status": "active"},
                                     {"DbiResourceId": "db-OTHER"}, {"DBInstanceArn": SOURCE + "-other"},
                                     {"Status": None}])
def test_changed_or_active_record_never_deleted(changes):
    fake = FakeAws(record(**changes))
    with pytest.raises(audit.BackupError):
        invoke(fake, execute=True)
    assert not any("delete-db-instance-automated-backup" in call for call in fake.calls)


def test_account_change_prevents_deletion():
    fake = FakeAws(record())
    fake.account = "999999999999"
    with pytest.raises(audit.BackupError):
        invoke(fake, execute=True)
    assert not any("delete-db-instance-automated-backup" in call for call in fake.calls)


def test_recheck_blocks_a_backup_that_starts_replicating():
    fake = FakeAws(record())
    descriptions = [0]
    def change(fake):
        descriptions[0] += 1
        if descriptions[0] == 2:
            fake.record["Status"] = "replicating"
    fake.before_describe = change
    with pytest.raises(audit.BackupError):
        invoke(fake, execute=True)
    assert not any("delete-db-instance-automated-backup" in call for call in fake.calls)


def test_absence_or_access_error_is_never_a_successful_delete():
    fake = FakeAws(None)
    result, code = invoke(fake, execute=True)
    assert code == 2 and result["status"] == "not_found"
    def denied(_):
        raise audit.BackupError("permission denied")
    with pytest.raises(audit.BackupError):
        audit.inspect_or_delete(ACCOUNT, BACKUP, SOURCE, DBI, execute=True, query=denied)


def test_wrong_region_or_ambiguous_records_fail_closed():
    with pytest.raises(audit.BackupError):
        audit.validate_identity(ACCOUNT, BACKUP.replace("us-west-2", "us-east-1"), SOURCE, DBI)
    def duplicate(args):
        return {"Account": ACCOUNT} if args[0] == "sts" else {"DBInstanceAutomatedBackups": [record(), record()]}
    with pytest.raises(audit.BackupError):
        audit.find_exact("us-west-2", ACCOUNT, BACKUP, SOURCE, DBI, query=duplicate)


def test_incomplete_list_and_lost_delete_response_fail_closed():
    def incomplete(args):
        return {"Account": ACCOUNT} if args[0] == "sts" else {"DBInstanceAutomatedBackups": [{}]}
    with pytest.raises(audit.BackupError):
        audit.find_exact("us-west-2", ACCOUNT, BACKUP, SOURCE, DBI, query=incomplete)
    fake = FakeAws(record())
    def lost(args):
        if "delete-db-instance-automated-backup" in args:
            fake.calls.append(args)
            fake.record = None
            raise audit.BackupError("lost delete response")
        return fake(args)
    with pytest.raises(audit.BackupError):
        audit.inspect_or_delete(ACCOUNT, BACKUP, SOURCE, DBI, execute=True, query=lost)
    assert len([call for call in fake.calls if "delete-db-instance-automated-backup" in call]) == 1


def test_one_transient_absence_does_not_confirm_deletion():
    fake = FakeAws(record())
    observations = [None, record(), None, None]
    after_delete = [False]
    def fluctuating(args):
        if "delete-db-instance-automated-backup" in args:
            after_delete[0] = True
            return fake(args)
        if "describe-db-instance-automated-backups" in args and after_delete[0]:
            fake.record = observations.pop(0)
        return fake(args)
    tick = [0.0]
    result, code = audit.inspect_or_delete(ACCOUNT, BACKUP, SOURCE, DBI, execute=True, query=fluctuating,
        clock=lambda: tick[0], sleep=lambda seconds: tick.__setitem__(0, tick[0] + seconds))
    assert code == 0 and result["status"] == "not_found_after_delete"
    assert tick[0] == 15.0


def test_error_message_does_not_print_cli_exception(monkeypatch, capsys):
    def fail(*_, **__):
        raise audit.BackupError("PRIVATE_ERROR_SHOULD_NOT_APPEAR")
    monkeypatch.setattr(audit, "inspect_or_delete", fail)
    code = audit.main(["--account", ACCOUNT, "--backup-arn", BACKUP, "--source-arn", SOURCE,
                       "--source-dbi-resource-id", DBI, "--execute"])
    assert code == 1
    assert "PRIVATE_ERROR_SHOULD_NOT_APPEAR" not in capsys.readouterr().err
