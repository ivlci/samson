# frozen_string_literal: true
require_relative "../../test_helper"

SingleCov.covered!

describe Kubernetes::RoleValidator do
  let(:deployment_role) do
    YAML.load_stream(read_kubernetes_sample_file('kubernetes_deployment.yml')).map(&:deep_symbolize_keys)
  end
  let(:role) { deployment_role }

  describe '.verify' do
    let(:spec) { role[0][:spec][:template][:spec] }
    let(:job_role) do
      [YAML.safe_load(read_kubernetes_sample_file('kubernetes_job.yml')).deep_symbolize_keys]
    end
    let(:cron_job_role) do
      [YAML.safe_load(read_kubernetes_sample_file('kubernetes_cron_job.yml')).deep_symbolize_keys]
    end
    let(:pod_role) do
      [{kind: 'Pod', metadata: {name: 'my-map', labels: labels}, spec: {containers: [{name: "foo"}]}}]
    end
    let(:labels) { {project: "some-project", role: "some-role"} }
    let(:stateful_set_role) do
      [
        deployment_role[1],
        {
          kind: 'StatefulSet',
          metadata: {name: 'my-map', labels: labels},
          spec: {
            serviceName: 'foobar',
            selector: {matchLabels: labels},
            template: {
              metadata: {labels: labels},
              spec: {containers: [{name: 'foo'}]}
            }
          }
        }
      ]
    end
    let(:role_json) { role.to_json }
    let(:errors) do
      elements = Kubernetes::Util.parse_file(role_json, 'fake.json').map(&:deep_symbolize_keys)
      Kubernetes::RoleValidator.new(elements).validate
    end

    it "works" do
      errors.must_be_nil
    end

    it "allows ConfigMap" do
      role_json[-1...-1] = ", #{{kind: 'ConfigMap', metadata: {name: 'my-map', labels: labels}}.to_json}"
      errors.must_equal nil
    end

    it "fails nicely with empty Hash template" do
      role_json.replace "{}"
      refute errors.empty?
    end

    it "fails nicely with empty Array template" do
      role_json.replace "[]"
      errors.must_equal ["No content found"]
    end

    it "fails nicely with false" do
      elements = Kubernetes::Util.parse_file('---', 'fake.yml')
      errors = Kubernetes::RoleValidator.new(elements).validate
      errors.must_equal ["No content found"]
    end

    it "fails nicely with bad template" do
      Kubernetes::RoleValidator.new(["bad", {kind: "Good"}]).validate.must_equal ["Only hashes supported"]
    end

    it "reports invalid types" do
      role.first[:kind] = "Ohno"
      errors.to_s.must_include "Unsupported combination of kinds: Ohno + Service, supported"
    end

    describe 'StatefulSet' do
      before do
        stateful_set_role[0][:metadata][:name] = 'foobar'
        stateful_set_role[1][:spec][:updateStrategy] = 'OnDelete'
        role.replace(stateful_set_role)
      end

      it "allows" do
        errors.must_equal nil
      end

      it "enforces service and serviceName consistency" do
        stateful_set_role[0][:metadata][:name] = 'nope'
        errors.must_equal ["Service metadata.name and StatefulSet spec.serviceName must be consistent"]
      end

      it "enforces updateStrategy" do
        stateful_set_role[1][:spec][:updateStrategy] = nil
        errors.first.must_include "updateStrategy"
      end
    end

    describe 'PodDisruptionBudget' do
      before do
        role.push(
          kind: 'PodDisruptionBudget',
          metadata: {name: 'foo', labels: labels},
          spec: {selector: {matchLabels: labels}}
        )
      end

      it "allows" do
        errors.must_equal nil
      end

      it "shows inconsistent labels" do
        role[0][:metadata][:labels][:project] = 'nope'
        errors.must_equal ["Project and role labels must be consistent across resources"]
      end

      it "shows eviction deadlock" do
        role.last[:spec][:minAvailable] = 2
        errors.must_equal [
          "PodDisruptionBudget spec.minAvailable must be lower than spec.replicas to avoid eviction deadlock"
        ]
      end

      it "allows correct minAvailable eviction" do
        role.last[:spec][:minAvailable] = 1
        errors.must_equal nil
      end
    end

    it "allows only Job" do
      role.replace(job_role)
      errors.must_be_nil
    end

    it "allows only CronJob" do
      role.replace(cron_job_role)
      errors.must_be_nil
    end

    it "reports missing name" do
      role.first[:metadata].delete(:name)
      errors.must_equal ["Needs a metadata.name"]
    end

    it "reports non-unique namespaces since that would break pod fetching" do
      role.first[:metadata][:namespace] = "default"
      errors.to_s.must_include "Namespaces need to be unique"
    end

    it "allows multiple services" do
      role << role.last.dup
      errors.must_be_nil
    end

    it "reports numeric cpu" do
      role.first[:spec][:template][:spec][:containers].first[:resources] = {limits: {cpu: 1}}
      errors.must_include "Numeric cpu resources are not supported"
    end

    it "reports missing containers" do
      role.first[:spec][:template][:spec].delete(:containers)
      errors.must_include "Deployment needs at least 1 container"
    end

    it "ignores unknown types" do
      role << {kind: 'Ooops'}
    end

    # if there are multiple containers they each need a name ... so enforcing this from the start
    it "reports missing name for containers" do
      spec[:containers][0].delete(:name)
      errors.must_equal ['Containers need a name']
    end

    it "reports bad container names" do
      spec[:containers][0][:name] = 'foo_bar'
      errors.must_equal ["Container name foo_bar did not match \\A[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\\z"]
    end

    # release_doc does not support that and it would lead to chaos
    it 'reports job mixed with deploy' do
      role.concat job_role
      errors.to_s.must_include "Unsupported combination of kinds: Deployment + Job + Service, supported"
    end

    it "reports non-string labels" do
      role.first[:metadata][:labels][:role_id] = 1
      errors.must_include "Deployment metadata.labels.role_id must be a String"
    end

    it "reports invalid labels" do
      role.first[:metadata][:labels][:role] = 'foo_bar'
      errors.must_include "Deployment metadata.labels.role must match /\\A[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\\z/"
    end

    it "allows valid labels" do
      role.first[:metadata][:labels][:foo] = 'KubeDNS'
      errors.must_be_nil
    end

    it "works with proper annotations" do
      role.first[:spec][:template][:metadata][:annotations] = {'secret/FOO' => 'bar'}
      errors.must_be_nil
    end

    it "reports invalid annotations" do
      role.first[:spec][:template][:metadata][:annotations] = ['foo', 'bar']
      errors.must_include "Annotations must be a hash"
    end

    it "reports non-string env values" do
      role.first[:spec][:template][:spec][:containers][0][:env] = {
        name: 'XYZ_PORT',
        value: 1234 # can happen when using yml configs
      }
      errors.must_include "Env values 1234 must be strings."
    end

    it "reports non-string annotations" do
      role.first[:metadata][:annotations] = {
        bar: true
      }
      role.first[:spec][:template][:metadata][:annotations] = {
        foo: 'XYZ_PORT',
        bar: 1234
      }
      errors.must_include "Annotation values true, 1234 must be strings."
    end

    describe "#validate_team_labels" do
      with_env KUBERNETES_ENFORCE_TEAMS: "true"

      before do
        role[0][:metadata][:labels][:team] = "hey"
        role[1][:metadata][:labels][:team] = "hey"
        role[0][:spec][:template][:metadata][:labels][:team] = "ho"
      end

      it "passes when labels are added" do
        errors.must_be_nil
      end

      it "passes when spec is not required" do
        role.delete :spec
        errors.must_be_nil
      end

      describe "with missing labels" do
        before do
          role[0][:metadata][:labels].delete :team
          role[0][:spec][:template][:metadata][:labels].delete :team
        end

        it "fails" do
          errors.must_equal ["metadata.labels.team must be set", "spec.template.metadata.labels.team must be set"]
        end

        it "does not fail when disabled" do
          with_env KUBERNETES_ENFORCE_TEAMS: nil do
            errors.must_be_nil
          end
        end
      end
    end

    describe "#validate_prerequisites" do
      before do
        role.pop
        role.first[:kind] = "Job"
        role.first[:spec][:template][:spec][:restartPolicy] = "Never"
        role.first[:spec][:template][:metadata][:annotations] = {"samson/prerequisite": 'true'}
      end

      it "does not report valid prerequisites" do
        errors.must_equal nil
      end

      it "does not report valid prerequisites for pod" do
        assert role.first.delete(:spec)
        role.first[:kind] = "Pod"
        role.first[:metadata][:annotations] = {"samson/prerequisite": 'true'}
        role.first[:spec] = {containers: [{name: "Foo"}]}
        errors.must_equal nil
      end

      it "reports invalid prerequisites" do
        role.first[:kind] = "Deployment"
        errors.must_include "Only elements with type Job, Pod can be prerequisites."
      end
    end

    describe 'pod' do
      let(:role) { pod_role }

      it "allows only Pod" do
        errors.must_equal nil
      end

      it "fails without containers" do
        role[0][:spec][:containers].clear
        errors.must_equal ["Pod needs at least 1 container"]
      end

      it "fails without name" do
        role[0][:spec][:containers][0].delete :name
        errors.must_equal ["Containers need a name"]
      end
    end

    describe '#validate_job_restart_policy' do
      let(:expected) { ["Job spec.template.spec.restartPolicy must be one of Never/OnFailure"] }
      before { role.replace(job_role) }

      it "reports missing restart policy" do
        spec.delete(:restartPolicy)
        errors.must_equal expected
      end

      it "reports bad restart policy" do
        spec[:restartPolicy] = 'Always'
        errors.must_equal expected
      end

      it "reports bad restart policy for CronJob" do
        role.replace(cron_job_role)
        role[0][:spec][:jobTemplate][:spec][:template][:spec][:restartPolicy] = 'Always'
        errors.must_equal ["CronJob spec.jobTemplate.spec.template.spec.restartPolicy must be one of Never/OnFailure"]
      end
    end

    describe '#validate_project_and_role_consistent' do
      let(:error_message) { "Project and role labels must be consistent across resources" }

      # this is not super important, but adding it for consistency
      it "reports missing job labels" do
        role.replace(job_role)
        role[0][:metadata][:labels].delete(:role)
        errors.must_equal [
          "Missing project or role for Job metadata.labels",
          error_message
        ]
      end

      it "reports missing labels" do
        role.first[:spec][:template][:metadata][:labels].delete(:project)
        errors.must_equal [
          "Missing project or role for Deployment spec.template.metadata.labels",
          error_message
        ]
      end

      it "allows cross-matching services when opted in" do
        role[1][:spec][:selector].delete(:role)
        role[1][:metadata][:annotations] = {"samson/service_selector_across_roles": "true"}
        errors.must_be_nil
      end

      it "reports missing label section" do
        role.first[:spec][:template][:metadata].delete(:labels)
        errors.must_equal [
          "Missing project or role for Deployment spec.template.metadata.labels",
          error_message
        ]
      end

      it "reports inconsistent deploy label" do
        role.first[:spec][:template][:metadata][:labels][:project] = 'other'
        errors.must_include error_message
      end

      it "reports inconsistent service label" do
        role.last[:spec][:selector][:project] = 'other'
        errors.must_include error_message
      end
    end

    describe "#validate_host_volume_paths" do
      with_env KUBERNETES_ALLOWED_VOLUME_HOST_PATHS: '/data/,/foo/bar'

      before do
        spec[:volumes] = [
          {hostPath: {path: '/data'}},
          {hostPath: {path: '/data/'}},
          {hostPath: {path: '/data/bar'}}, # subdirectories are ok too
          {hostPath: {path: '/foo/bar/'}}
        ]
      end

      it "allows valid paths" do
        errors.must_be_nil
      end

      it "does not allow bad paths" do
        spec[:volumes][0][:hostPath][:path] = "/foo"
        errors.must_equal ["Only volume host paths /data/, /foo/bar/ are allowed, not /foo/."]
      end
    end

    describe "#validate_not_matching_team" do
      it "reports bad selector" do
        role.last[:spec][:selector][:team] = 'foo'
        errors.must_equal ["Team names change, do not select or match on them"]
      end

      it "reports bad matchLabels" do
        role.first[:spec][:selector][:matchLabels][:team] = 'foo'
        errors.must_equal ["Team names change, do not select or match on them"]
      end
    end
  end

  describe '.map_attributes' do
    def call(path, elements)
      Kubernetes::RoleValidator.new(elements).send(:map_attributes, path)
    end

    it "finds simple" do
      call([:a], [{a: 1}, {a: 2}]).must_equal [1, 2]
    end

    it "finds nested" do
      call([:a, :b], [{a: {b: 1}}, {a: {b: 2}}]).must_equal [1, 2]
    end

    it "finds arrays" do
      call([:a], [{a: [1]}, {a: [2]}]).must_equal [[1], [2]]
    end

    it "finds through nested arrays" do
      call([:a, :b], [{a: [{b: 1}, {b: 2}]}, {a: [{b: 3}]}]).must_equal [[1, 2], [3]]
    end
  end

  describe '.validate_groups' do
    def validate_error(roles)
      Kubernetes::RoleValidator.validate_groups(roles)
    rescue Samson::Hooks::UserError
      $!.message
    end

    it "is valid with no role" do
      Kubernetes::RoleValidator.validate_groups([])
    end

    it "is valid with a single role" do
      Kubernetes::RoleValidator.validate_groups([[role.first]])
    end

    it "is valid with multiple different roles" do
      primary = role.first
      primary2 = primary.dup
      primary2[:metadata] = {labels: {role: "meh", project: primary.dig(:metadata, :labels, :project)}}
      Kubernetes::RoleValidator.validate_groups([[primary], [primary2]])
    end

    it "is valid with a duplicate role but magic annotation" do
      role.first[:metadata][:annotations] = {"samson/multi_project": "true"}
      Kubernetes::RoleValidator.validate_groups([[role.first], [role.first]])
    end

    it "is invalid with a duplicate role" do
      validate_error([[role.first], [role.first]]).must_equal "metadata.labels.role must be set and unique"
    end

    it "is invalid with different projects" do
      primary = role.first
      primary2 = primary.dup
      primary2[:metadata] = {labels: {role: "meh", project: "other"}}
      validate_error([[primary], [primary2]]).must_equal "metadata.labels.project must be consistent"
    end

    it "is invalid with different role labels in a single role" do
      primary = role.first
      primary2 = primary.dup
      primary2[:metadata] = {labels: {role: "meh", project: primary.dig(:metadata, :labels, :project)}}
      validate_error([[primary, primary2]]).must_equal(
        "metadata.labels.role must be set and consistent in each config file"
      )
    end

    it "is invalid when a role is not set" do
      primary = role.first
      primary2 = primary.dup
      primary2[:metadata] = {labels: {project: primary.dig(:metadata, :labels, :project)}}
      validate_error([[primary, primary2]]).must_equal(
        "metadata.labels.role must be set and consistent in each config file"
      )
    end

    it "is invalid when all role are not set" do
      primary = role.first
      primary[:metadata][:labels].delete :role
      validate_error([[primary, primary]]).must_equal(
        "metadata.labels.role must be set and consistent in each config file"
      )
    end
  end
end
