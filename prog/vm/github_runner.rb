# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::GithubRunner < Prog::Base
  subject_is :github_runner

  semaphore :destroy

  def self.assemble(installation, repository_name:, label:)
    ssh_key = SshKey.generate

    DB.transaction do
      ubid = GithubRunner.generate_ubid

      # We use unencrypted storage for now, because provisioning 86G encrypted
      # storage takes ~8 minutes. Unencrypted disk uses `cp` command instead
      # of `spdk_dd` and takes ~3 minutes. If btrfs disk mounted, it decreases to
      # ~10 seconds.
      # TODO: Add more labels to allow user to choose size and location
      vm_st = Prog::Vm::Nexus.assemble(
        ssh_key.public_key,
        installation.project.id,
        name: ubid.to_s,
        size: "standard-2",
        unix_user: "runner",
        location: "hetzner-hel1",
        boot_image: "github-ubuntu-2204",
        storage_size_gib: 86,
        enable_ip4: true,
        storage_encrypted: false
      )

      Sshable.create(
        unix_user: "runner",
        host: "temp_#{vm_st.id}",
        raw_private_key_1: ssh_key.keypair
      ) { _1.id = vm_st.id }

      github_runner = GithubRunner.create(
        installation_id: installation.id,
        repository_name: repository_name,
        label: label,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Vm::GithubRunner", label: "start") { _1.id = github_runner.id }
    end
  end

  def vm
    @vm ||= github_runner.vm
  end

  def github_client
    @github_client ||= Github.installation_client(github_runner.installation.installation_id)
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    vm.sshable.update(host: vm.ephemeral_net4)
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "common", "subject_id" => vm.id, "user" => "runner"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_install_actions_runner if leaf?
    donate
  end

  # TODO: Move this to golden image too
  label def install_actions_runner
    vm.sshable.cmd("curl -o actions-runner-linux-x64-2.308.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.308.0/actions-runner-linux-x64-2.308.0.tar.gz")
    vm.sshable.cmd("echo '9f994158d49c5af39f57a65bf1438cbae4968aec1e4fec132dd7992ad57c74fa  actions-runner-linux-x64-2.308.0.tar.gz' | shasum -a 256 -c")
    vm.sshable.cmd("tar xzf ./actions-runner-linux-x64-2.308.0.tar.gz")

    hop_register_runner
  end

  label def register_runner
    unless github_runner.runner_id
      # We use generate-jitconfig instead of registration-token because it's
      # recommended by GitHub for security reasons.
      # https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-just-in-time-runners
      data = {name: github_runner.ubid.to_s, labels: ["ubicloud"], runner_group_id: 1}
      response = github_client.post("/repos/#{github_runner.repository_name}/actions/runners/generate-jitconfig", data)
      github_runner.update(runner_id: response[:runner][:id], ready_at: Time.now)
      vm.sshable.cmd("common/bin/daemonizer 'sudo -u runner /home/runner/run.sh --jitconfig #{response[:encoded_jit_config].shellescape}' runner-script")
    end

    case vm.sshable.cmd("common/bin/daemonizer --check runner-script")
    when "Succeeded", "InProgress"
      hop_wait
    when "Failed"
      github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      github_runner.update(runner_id: nil, ready_at: nil)
    end
    nap 10
  end

  label def wait
    # If the runner doesn't pick a job in two minutes, destroy it
    if github_runner.job_id.nil? && Time.now > github_runner.ready_at + 60 * 2
      response = github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      unless response[:busy]
        github_runner.incr_destroy
        puts "Destroying GithubRunner[#{github_runner.ubid}] because it does not pick a job in two minutes"
        nap 0
      end
    end

    if vm.sshable.cmd("common/bin/daemonizer --check runner-script") == "Succeeded"
      github_runner.incr_destroy
      nap 0
    end

    nap 15
  end

  label def destroy
    register_deadline(nil, 10 * 60)

    decr_destroy

    # Waiting 404 Not Found response for get runner request
    begin
      github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      nap 5
    rescue Octokit::NotFound
    end

    vm.private_subnets.each { _1.incr_destroy }
    vm.sshable.destroy
    vm.incr_destroy

    hop_wait_vm_destroy
  end

  label def wait_vm_destroy
    nap 10 unless vm.nil?

    github_runner.destroy
    pop "github runner deleted"
  end
end