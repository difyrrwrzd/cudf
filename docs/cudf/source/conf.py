# Copyright (c) 2018-2024, NVIDIA CORPORATION.
#
# cudf documentation build configuration file, created by
# sphinx-quickstart on Wed May  3 10:59:22 2017.
#
# This file is execfile()d with the current directory set to its
# containing dir.
#
# Note that not all possible configuration values are present in this
# autogenerated file.
#
# All configuration values have a default; values that are commented out
# serve to show the default.

# If extensions (or modules to document with autodoc) are in another directory,
# add these directories to sys.path here. If the directory is relative to the
# documentation root, use os.path.abspath to make it absolute, like shown here.
#
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

from docutils.nodes import Text
from sphinx.addnodes import pending_xref
from sphinx.highlighting import lexers
from sphinx.ext import intersphinx
from pygments.lexer import RegexLexer
from pygments.token import Text as PText


class PseudoLexer(RegexLexer):
    """Trivial lexer for pseudocode."""

    name = "pseudocode"
    aliases = ["pseudo"]
    tokens = {
        "root": [
            (r".*\n", PText),
        ]
    }


lexers["pseudo"] = PseudoLexer()

# -- Custom Extensions ----------------------------------------------------
sys.path.append(os.path.abspath("./_ext"))

# -- General configuration ------------------------------------------------

# If your documentation needs a minimal Sphinx version, state it here.
#
# needs_sphinx = '1.0'

# Add any Sphinx extension module names here, as strings. They can be
# extensions coming with Sphinx (named 'sphinx.ext.*') or your custom
# ones.
extensions = [
    "breathe",
    "sphinx.ext.intersphinx",
    "sphinx.ext.autodoc",
    "sphinx.ext.autosummary",
    "sphinx_copybutton",
    "numpydoc",
    "IPython.sphinxext.ipython_console_highlighting",
    "IPython.sphinxext.ipython_directive",
    "PandasCompat",
    "myst_nb",
]


# Preprocess doxygen xml for compatibility with latest Breathe
def clean_definitions(root):
    # Breathe can't handle SFINAE properly:
    # https://github.com/breathe-doc/breathe/issues/624
    seen_ids = set()
    for sectiondef in root.findall(".//sectiondef"):
        for memberdef in sectiondef.findall("./memberdef"):
            id_ = memberdef.get("id")
            for tparamlist in memberdef.findall("./templateparamlist"):
                for param in tparamlist.findall("./param"):
                    for type_ in param.findall("./type"):
                        # CUDF_ENABLE_IF or std::enable_if
                        if "enable_if" in ET.tostring(type_).decode().lower():
                            if id_ not in seen_ids:
                                # If this is the first time we're seeing this function,
                                # just remove the template parameter.
                                seen_ids.add(id_)
                                tparamlist.remove(param)
                            else:
                                # Otherwise, remove the overload altogether and just
                                # rely on documenting one of the SFINAE overloads.
                                sectiondef.remove(memberdef)
                            break

                        # In addition to enable_if, check for overloads set up by
                        # ...*=nullptr.
                        for type_ in param.findall("./defval"):
                            if "nullptr" in ET.tostring(type_).decode():
                                try:
                                    tparamlist.remove(param)
                                except ValueError:
                                    # May have already been removed in above,
                                    # so skip.
                                    pass
                                break

    # All of these in type declarations cause Breathe to choke.
    # For friend, see https://github.com/breathe-doc/breathe/issues/916
    strings_to_remove = (
        "__forceinline__",
        "CUDF_HOST_DEVICE",
        "decltype(auto)",
        "friend",
    )
    for node in root.iter():
        for string in strings_to_remove:
            if node.text is not None:
                node.text = node.text.replace(string, "")
            if node.tail is not None:
                node.tail = node.tail.replace(string, "")


def clean_all_xml_files(path):
    for fn in glob.glob(os.path.join(path, "*.xml")):
        tree = ET.parse(fn)
        clean_definitions(tree.getroot())
        tree.write(fn)


# Breathe Configuration
breathe_projects = {"libcudf": "../../../cpp/doxygen/xml"}
for project_path in breathe_projects.values():
    clean_all_xml_files(project_path)
breathe_default_project = "libcudf"


nb_execution_excludepatterns = ["performance-comparisons.ipynb"]

nb_execution_mode = "force"
nb_execution_timeout = 300

copybutton_prompt_text = ">>> "
autosummary_generate = True

# Enable automatic generation of systematic, namespaced labels for sections
myst_heading_anchors = 2

# Add any paths that contain templates here, relative to this directory.
templates_path = ["_templates"]

# The suffix(es) of source filenames.
# You can specify multiple suffix as a list of string:
#
# source_suffix = ['.rst', '.md']
source_suffix = {".rst": "restructuredtext"}

# The master toctree document.
master_doc = "index"

# General information about the project.
project = "cudf"
copyright = "2018-2023, NVIDIA Corporation"
author = "NVIDIA Corporation"

# The version info for the project you're documenting, acts as replacement for
# |version| and |release|, also used in various other places throughout the
# built documents.
#
# The short X.Y version.
version = "24.04"
# The full version, including alpha/beta/rc tags.
release = "24.04.00"

# The language for content autogenerated by Sphinx. Refer to documentation
# for a list of supported languages.
#
# This is also used if you do content translation via gettext catalogs.
# Usually you set "language" from the command line for these cases.
language = "en"

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This patterns also effect to html_static_path and html_extra_path
exclude_patterns = [
    "venv",
    "**/includes/**",
]

# The name of the Pygments (syntax highlighting) style to use.
pygments_style = "sphinx"

html_theme_options = {
    "external_links": [],
    # https://github.com/pydata/pydata-sphinx-theme/issues/1220
    "icon_links": [],
    "github_url": "https://github.com/rapidsai/cudf",
    "twitter_url": "https://twitter.com/rapidsai",
    "show_toc_level": 1,
    "navbar_align": "right",
    "navigation_with_keys": True,
}
include_pandas_compat = True


# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#

html_theme = "pydata_sphinx_theme"
html_logo = "_static/RAPIDS-logo-purple.png"


# Theme options are theme-specific and customize the look and feel of a theme
# further.  For a list of options available for each theme, see the
# documentation.
#
# html_theme_options = {}

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
html_static_path = ["_static"]


# -- Options for HTMLHelp output ------------------------------------------

# Output file base name for HTML help builder.
htmlhelp_basename = "cudfdoc"


# -- Options for LaTeX output ---------------------------------------------

latex_elements = {
    # The paper size ('letterpaper' or 'a4paper').
    #
    # 'papersize': 'letterpaper',
    # The font size ('10pt', '11pt' or '12pt').
    #
    # 'pointsize': '10pt',
    # Additional stuff for the LaTeX preamble.
    #
    # 'preamble': '',
    # Latex figure (float) alignment
    #
    # 'figure_align': 'htbp',
}

# Grouping the document tree into LaTeX files. List of tuples
# (source start file, target name, title,
#  author, documentclass [howto, manual, or own class]).
latex_documents = [
    (
        master_doc,
        "cudf.tex",
        "cudf Documentation",
        "NVIDIA Corporation",
        "manual",
    )
]


# -- Options for manual page output ---------------------------------------

# One entry per manual page. List of tuples
# (source start file, name, description, authors, manual section).
man_pages = [(master_doc, "cudf", "cudf Documentation", [author], 1)]


# -- Options for Texinfo output -------------------------------------------

# Grouping the document tree into Texinfo files. List of tuples
# (source start file, target name, title, author,
#  dir menu entry, description, category)
texinfo_documents = [
    (
        master_doc,
        "cudf",
        "cudf Documentation",
        author,
        "cudf",
        "One line description of project.",
        "Miscellaneous",
    )
]


# Example configuration for intersphinx: refer to the Python standard library.
intersphinx_mapping = {
    "cupy": ("https://docs.cupy.dev/en/stable/", None),
    "dlpack": ("https://dmlc.github.io/dlpack/latest/", None),
    "numpy": ("https://numpy.org/doc/stable", None),
    "pandas": ("https://pandas.pydata.org/docs/", None),
    "pyarrow": ("https://arrow.apache.org/docs/", None),
    "python": ("https://docs.python.org/3", None),
    "rmm": ("https://docs.rapids.ai/api/rmm/nightly/", None),
    "typing_extensions": (
        "https://typing-extensions.readthedocs.io/en/stable/",
        None,
    ),
}

# Config numpydoc
numpydoc_show_inherited_class_members = {
    # option_context inherits undocumented members from the parent class
    "cudf.option_context": False,
}

# Rely on toctrees generated from autosummary on each of the pages we define
# rather than the autosummaries on the numpydoc auto-generated class pages.
numpydoc_class_members_toctree = False
numpydoc_attributes_as_param_list = False

autoclass_content = "class"

# Replace API shorthands with fullname
_reftarget_aliases = {
    "cudf.Series": ("cudf.core.series.Series", "cudf.Series"),
    "cudf.Index": ("cudf.core.index.Index", "cudf.Index"),
    "cupy.core.core.ndarray": ("cupy.ndarray", "cupy.ndarray"),
}


def resolve_aliases(app, doctree):
    pending_xrefs = doctree.traverse(condition=pending_xref)
    for node in pending_xrefs:
        alias = node.get("reftarget", None)
        if alias is not None and alias in _reftarget_aliases:
            real_ref, text_to_render = _reftarget_aliases[alias]
            node["reftarget"] = real_ref

            text_node = next(
                iter(node.traverse(lambda n: n.tagname == "#text"))
            )
            text_node.parent.replace(text_node, Text(text_to_render, ""))


def _generate_namespaces(namespaces):
    all_namespaces = []
    for base_namespace, other_namespaces in namespaces.items():
        all_namespaces.append(base_namespace + "::")
        for other_namespace in other_namespaces:
            all_namespaces.append(f"{other_namespace}::")
            all_namespaces.append(f"{base_namespace}::{other_namespace}::")
    return all_namespaces


_all_namespaces = _generate_namespaces(
    {
        # Note that io::datasource is actually a nested class
        "cudf": {"io", "io::datasource", "strings", "ast", "ast::expression"},
        "numeric": {},
        "nvtext": {},
    }
)

_names_to_skip = {
    # External names
    "thrust",
    "cuda",
    "arrow",
    # Unknown types
    "int8_t",
    "int16_t",
    "int32_t",
    "int64_t",
    "__int128_t",
    "size_t",
    "uint8_t",
    "uint16_t",
    "uint32_t",
    "uint64_t",
    # Internal objects
    "id_to_type_impl",
    "type_to_scalar_type_impl",
    "type_to_scalar_type_impl",
    "detail",
    # kafka objects
    "python_callable_type",
    "kafka_oauth_callback_wrapper_type",
    # Template types
    "Radix",
    # Unsupported by Breathe
    # https://github.com/breathe-doc/breathe/issues/355
    "deprecated",
    # TODO: This is currently in a src file but perhaps should be public
    "orc::column_statistics",
    # Sphinx doesn't know how to distinguish between the ORC and Parquet
    # definitions because Breathe doesn't to preserve namespaces for enums.
    "TypeKind",
}

_domain_objects = None
_prefixed_domain_objects = None
_intersphinx_cache = {}

_intersphinx_extra_prefixes = ("rmm", "rmm::mr", "mr")


def _cached_intersphinx_lookup(env, node, contnode):
    """Perform an intersphinx lookup and cache the result.

    Have to manually manage the intersphinx cache because lru_cache doesn't
    handle the env object properly.
    """
    key = (node, contnode)
    if key in _intersphinx_cache:
        return _intersphinx_cache[key]
    if (
        ref := intersphinx.resolve_reference_detect_inventory(
            env, node, contnode
        )
    ) is not None:
        _intersphinx_cache[key] = ref
    return ref


def on_missing_reference(app, env, node, contnode):
    # These variables are defined outside the function to speed up the build.
    global _all_namespaces, _names_to_skip, _intersphinx_extra_prefixes, _domain_objects, _prefixed_domain_objects, _intersphinx_cache

    # Precompute and cache domains for faster lookups
    if _domain_objects is None:
        _domain_objects = {}
        _prefixed_domain_objects = {}
        for name, _, _, docname, _, _ in env.domains["cpp"].get_objects():
            _domain_objects[name] = docname
            for prefix in _all_namespaces:
                _prefixed_domain_objects[f"{prefix}{name}"] = name

    reftarget = node.get("reftarget")
    if reftarget == "cudf.core.index.GenericIndex":
        # We don't exposed docs for `cudf.core.index.GenericIndex`
        # hence we would want the docstring & mypy references to
        # use `cudf.Index`
        node["reftarget"] = "cudf.Index"
        return contnode
    if "namespacecudf" in reftarget:
        node["reftarget"] = "cudf"
        return contnode
    if "classcudf_1_1column__device__view_" in reftarget:
        node["reftarget"] = "cudf::column_device_view"
        return contnode

    if (refid := node.get("refid")) is not None and "hpp" in refid:
        # We don't want to link to C++ header files directly from the
        # Sphinx docs, those are pages that doxygen automatically
        # generates. Adding those would clutter the Sphinx output.
        return contnode

    if node["refdomain"] in ("std", "cpp") and reftarget is not None:
        if any(toskip in reftarget for toskip in _names_to_skip):
            return contnode

        # Strip template parameters and just use the base type.
        if match := re.search("(.*)<.*>", reftarget):
            reftarget = match.group(1)

        # Try to find the target prefixed with e.g. namespaces in case that's
        # all that's missing.
        # We need to do this search because the call sites may not have used
        # the namespaces and we don't want to force them to, and we have to
        # consider both directions because of issues like
        # https://github.com/breathe-doc/breathe/issues/860
        # (there may be other related issues, I haven't investigated all
        # possible combinations of failures in depth).
        if (name := _prefixed_domain_objects.get(reftarget)) is None:
            for prefix in _all_namespaces:
                if f"{prefix}{reftarget}" in _domain_objects:
                    name = f"{prefix}{reftarget}"
                    break
        if name is not None:
            return env.domains["cpp"].resolve_xref(
                env,
                _domain_objects[name],
                app.builder,
                node["reftype"],
                name,
                node,
                contnode,
            )

        # Final possibility is an intersphinx lookup to see if the symbol
        # exists in one of the other inventories. First we check the symbol
        # itself in case it was originally templated and that caused the lookup
        # to fail.
        if reftarget != node["reftarget"]:
            node["reftarget"] = reftarget
            if (
                ref := _cached_intersphinx_lookup(env, node, contnode)
            ) is not None:
                return ref

        # If the template wasn't the (only) issue, we check the various
        # namespace prefixes that may need to be added or removed.
        for prefix in _intersphinx_extra_prefixes:
            if prefix not in reftarget:
                node["reftarget"] = f"{prefix}::{reftarget}"
                if (
                    ref := _cached_intersphinx_lookup(env, node, contnode)
                ) is not None:
                    return ref
            else:
                node["reftarget"] = reftarget.replace(f"{prefix}::", "")
                if (
                    ref := _cached_intersphinx_lookup(env, node, contnode)
                ) is not None:
                    return ref

    return None


nitpick_ignore = [
    ("py:class", "SeriesOrIndex"),
    ("py:class", "Dtype"),
    # TODO: Remove this when we figure out why typing_extensions doesn't seem
    # to map types correctly for intersphinx
    ("py:class", "typing_extensions.Self"),
]


def setup(app):
    app.add_css_file("https://docs.rapids.ai/assets/css/custom.css")
    app.add_js_file(
        "https://docs.rapids.ai/assets/js/custom.js", loading_method="defer"
    )
    app.connect("doctree-read", resolve_aliases)
    app.connect("missing-reference", on_missing_reference)
