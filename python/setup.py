from setuptools import setup
from pathlib import Path
import re
import os

version = os.getenv('VERSION', '0.0.0')

setup(
    name="kestra",
    version=version
    .replace("v", ""),
    package_dir={"": "src"},
    include_package_data=True,
    install_requires=["requests"],
    extras_require={
        'test': ["pytest", "requests_mock"],
    },
    python_requires=">=3",
    description="Kestra is an infinitely scalable orchestration and scheduling platform, creating, running, scheduling, and monitoring millions of complex pipelines.",
    long_description=(Path(__file__).parent / "README.md").read_text(),
    long_description_content_type="text/markdown",
    url="https://kestra.io",
    author="Kestra",
    author_email="hello@kestra.io",
    license="Apache License 2.0",
    platforms="any",
    classifiers=[
        "License :: OSI Approved :: Apache Software License",
        "Programming Language :: Python",
        "Programming Language :: Python :: 3",
    ],
)
