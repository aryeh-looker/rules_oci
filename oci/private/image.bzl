"Implementation details for container rule"
_attrs = {
    "base": attr.label(allow_single_file = True, doc = "TODO"),
    "tars": attr.label_list(allow_files = True, doc = "List of tar files to add to the image as layers."),
    # See: https://github.com/opencontainers/image-spec/blob/main/config.md#properties
    "entrypoint": attr.string_list(doc = "A list of arguments to use as the command to execute when the container starts. These values act as defaults and may be replaced by an entrypoint specified when creating a container."),
    "cmd": attr.string_list(doc = "Default arguments to the entrypoint of the container. These values act as defaults and may be replaced by any specified when creating a container. If an Entrypoint value is not specified, then the first entry of the Cmd array SHOULD be interpreted as the executable to run."),
    "env": attr.string_dict(doc = """
Default values to the environment variables of the container. These values act as defaults and are merged with any specified when creating a container. Entries replace the base environment variables if any of the entries has the same key.
To merge entries with keys specified in the base, `${KEY}` or `$KEY` syntax may be used.
"""),
    "user": attr.string(doc = """
The username or UID which is a platform-specific structure that allows specific control over which user the process run as. 
This acts as a default value to use when the value is not specified when creating a container. 
For Linux based systems, all of the following are valid: user, uid, user:group, uid:gid, uid:group, user:gid. 
If group/gid is not specified, the default group and supplementary groups of the given user/uid in /etc/passwd from the container are applied.
"""),
    "workdir": attr.string(doc = "Sets the current working directory of the entrypoint process in the container. This value acts as a default and may be replaced by a working directory specified when creating a container."),
    "os": attr.string(doc = "The name of the operating system which the image is built to run on."),
    "architecture": attr.string(doc = "The CPU architecture which the binaries in this image are built to run on."),
    "variant": attr.string(doc = "The variant of the specified CPU architecture."),
    "_image_sh_tpl": attr.label(default = "image.sh.tpl", allow_single_file = True),
}

def _format_string_to_string(kv):
    return "%s=%s" % kv

def _platform_str(os, arch, variant = None):
    parts = [os, arch]
    if variant:
        parts.append(variant)
    return "/".join(parts)

def _impl(ctx):

    if not ctx.attr.base:
        if not ctx.attr.os or not ctx.attr.architecture:
            fail("os and architecture is mandatory when base in unspecified.")

    crane = ctx.toolchains["@contrib_rules_oci//oci:crane_toolchain_type"]
    registry = ctx.toolchains["@contrib_rules_oci//oci:registry_toolchain_type"]
    jq = ctx.toolchains["@aspect_bazel_lib//lib:jq_toolchain_type"]

    launcher = ctx.actions.declare_file("image_%s.sh" % ctx.label.name)
    ctx.actions.expand_template(
        template = ctx.file._image_sh_tpl,
        output = launcher,
        is_executable = True,
        substitutions = {
            "{{registry_launcher_path}}": registry.registry_info.launcher_path,
            "{{crane_path}}": crane.crane_info.crane_path,
            "{{jq_path}}": jq.jqinfo.bin.path,
            "{{storage_dir}}": "/".join([ctx.bin_dir.path, ctx.label.package, "storage_%s" % ctx.label.name]),
        }
    )

    inputs_depsets = []
    base = "oci:empty_base"

    if ctx.attr.base:
        base = "oci:layout/%s" % ctx.file.base.path
        inputs_depsets.append(depset([ctx.file.base]))

    args = ctx.actions.args()

    args.add_all([
        "mutate",
        base,
        "--tag",
        "oci:registry/{}".format(ctx.label.name),
    ])

    # add platform
    if ctx.attr.os and ctx.attr.architecture:
        args.add(_platform_str(ctx.attr.os, ctx.attr.architecture, ctx.attr.variant), format = "--platform=%s")
    
    # add layers
    for layer in ctx.attr.tars:
        # TODO(thesayyn): allow only .tar files
        inputs_depsets.append(layer[DefaultInfo].files)
        args.add_all(layer[DefaultInfo].files, format_each = "--append=%s")

    if ctx.attr.entrypoint:
        args.add_joined("--entrypoint", ctx.attr.entrypoint, join_with = ",")

    if ctx.attr.cmd:
        args.add_joined("--cmd", ctx.attr.cmd, join_with = ",")

    if ctx.attr.user:
        args.add(ctx.attr.user, format = "--user=%s")
    
    if ctx.attr.workdir:
        args.add(ctx.attr.workdir, format = "--workdir=%s")

    if ctx.attr.env:
        args.add_all(ctx.attr.env.items(), map_each = _format_string_to_string, format_each = "--env=%s")

    output = ctx.actions.declare_directory(ctx.label.name)
    args.add(output.path, format = "--output=%s")

    ctx.actions.run(
        inputs = depset(transitive = inputs_depsets),
        arguments = [args],
        outputs = [output],
        executable = launcher,
        tools = crane.crane_info.crane_files + registry.registry_info.registry_files + [jq.jqinfo.bin],
        progress_message = "OCI Image %{label}",
    )

    return [
        DefaultInfo(
            files = depset([output]),
        ),
    ]

oci_image = rule(
    implementation = _impl,
    attrs = _attrs,
    toolchains = [
        "@contrib_rules_oci//oci:crane_toolchain_type",
        "@contrib_rules_oci//oci:registry_toolchain_type",
        "@aspect_bazel_lib//lib:jq_toolchain_type"
    ],
)