# The stdout callback this repo runs with. See stdout_callback in ansible.cfg.
#
# A provisioning run is a hundred tasks and most of them are conditions being
# checked — "Is linger already enabled?", "Does this timezone exist?". On a box
# that is already provisioned every one of those is `ok`, and the interesting
# lines (what changed, what failed, what the run wants you to do next) are
# spread over three screens of output that says nothing happened.
#
# So: an `ok` task prints only if it has something to say. In practice that
# means the debug tasks — those set _ansible_verbose_always, which is what
# `-v` sets for every task, and is exactly the "print my result" flag we want.
# Everything else the default callback does is unchanged: changed, failed,
# unreachable, the handlers, the recap.
#
# `-v` turns the full output back on, because then _run_is_verbose() is true
# for every result. So does display_ok_hosts = True in ansible.cfg.
#
# This subclasses the in-core default callback rather than reimplementing it —
# it is the one callback guaranteed to be present, and inheriting keeps the
# formatting identical to what everyone expects from ansible-playbook.
from __future__ import annotations

from ansible.playbook.task_include import TaskInclude
from ansible.plugins.callback.default import CallbackModule as Default

DOCUMENTATION = """
    name: concise
    type: stdout
    short_description: default output, minus the tasks that changed nothing
    description:
      - Identical to the default callback, except that a task which ends C(ok)
        prints nothing unless it has a result to show (a debug message, or any
        run with C(-v)).
    extends_documentation_fragment:
      - default_callback
      - result_format_callback
    requirements:
      - set as stdout in configuration
"""


class CallbackModule(Default):

    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'concise'

    def v2_runner_on_ok(self, result):
        # An include is structure, not work: a banner and an "included:" line
        # for something whose own tasks announce themselves anyway.
        # result.task on ansible-core 2.19+, result._task before it: this repo
        # installs whatever ansible-core the distribution ships.
        task = getattr(result, 'task', None) or result._task
        if isinstance(task, TaskInclude) and not self._display.verbosity:
            return
        self._unless_it_speaks(super().v2_runner_on_ok, result)

    def v2_playbook_on_include(self, included_file):
        if self._display.verbosity:
            super().v2_playbook_on_include(included_file)

    def v2_runner_item_on_ok(self, result):
        self._unless_it_speaks(super().v2_runner_item_on_ok, result)

    def _unless_it_speaks(self, handler, result):
        # The default callback drops `ok` results when display_ok_hosts is
        # false — including the task banner, which it prints lazily for this
        # very reason. All this has to do is turn the option back on around
        # the results that do have something to print.
        showing = self.get_option('display_ok_hosts')
        if showing or not self._run_is_verbose(result):
            handler(result)
            return
        self.set_option('display_ok_hosts', True)
        try:
            handler(result)
        finally:
            self.set_option('display_ok_hosts', showing)
