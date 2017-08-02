#!/usr/bin/env python

# Copyright 2017 The Openstack-Helm Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import base64
import errno
import grp
import logging
import os
import pwd
import re
import six
import subprocess
import sys

import requests

FERNET_DIR = os.environ['KEYSTONE_KEYS_REPOSITORY']
KEYSTONE_USER = os.environ['KEYSTONE_USER']
KEYSTONE_GROUP = os.environ['KEYSTONE_GROUP']
SECRET_NAME = 'keystone-fernet-keys'
NAMESPACE = os.environ['KUBERNETES_NAMESPACE']

# k8s connection data
KUBE_HOST = None
KUBE_CERT = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
KUBE_TOKEN = None

LOG_DATEFMT = "%Y-%m-%d %H:%M:%S"
LOG_FORMAT = "%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s"
logging.basicConfig(format=LOG_FORMAT, datefmt=LOG_DATEFMT)
LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)


def read_kube_config():
    global KUBE_HOST, KUBE_TOKEN
    KUBE_HOST = "https://%s:%s" % ('kubernetes.default',
                                   os.environ['KUBERNETES_SERVICE_PORT'])
    with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
        KUBE_TOKEN = f.read()


def get_secret_definition(name):
    url = '%s/api/v1/namespaces/%s/secrets/%s' % (KUBE_HOST, NAMESPACE, name)
    resp = requests.get(url,
                        headers={'Authorization': 'Bearer %s' % KUBE_TOKEN},
                        verify=KUBE_CERT)
    if resp.status_code != 200:
        LOG.error('Cannot get secret %s.', name)
        LOG.error(resp.text)
        return None
    return resp.json()


def update_secret(name, secret):
    url = '%s/api/v1/namespaces/%s/secrets/%s' % (KUBE_HOST, NAMESPACE, name)
    resp = requests.put(url,
                        json=secret,
                        headers={'Authorization': 'Bearer %s' % KUBE_TOKEN},
                        verify=KUBE_CERT)
    if resp.status_code != 200:
        LOG.error('Cannot update secret %s.', name)
        LOG.error(resp.text)
        return False
    return True


def read_from_files():
    keys = filter(
        lambda name: os.path.isfile(FERNET_DIR + name) and re.match("^\d+$",
                                                                    name),
        os.listdir(FERNET_DIR)
    )
    data = {}
    for key in keys:
        with open(FERNET_DIR + key, 'r') as f:
            data[key] = f.read()
    if len(keys):
        LOG.debug("Keys read from files: %s", keys)
    else:
        LOG.warn("No keys were read from files.")
    return data


def get_keys_data():
    keys = read_from_files()
    return dict([(key, base64.b64encode(value.encode()).decode())
                for (key, value) in six.iteritems(keys)])


def write_to_files(data):
    if not os.path.exists(os.path.dirname(FERNET_DIR)):
        try:
            os.makedirs(os.path.dirname(FERNET_DIR))
        except OSError as exc: # Guard against race condition
            if exc.errno != errno.EEXIST:
                raise
        uid = pwd.getpwnam(KEYSTONE_USER).pw_uid
        gid = grp.getgrnam(KEYSTONE_GROUP).gr_gid
        os.chown(FERNET_DIR, uid, gid)

    for (key, value) in six.iteritems(data):
        with open(FERNET_DIR + key, 'w') as f:
            decoded_value = base64.b64decode(value).decode()
            f.write(decoded_value)
            LOG.debug("Key %s: %s", key, decoded_value)
    LOG.info("%s keys were written", len(data))


def execute_command(cmd):
    LOG.info("Executing 'keystone-manage %s --keystone-user=%s "
             "--keystone-group=%s' command.",
             cmd, KEYSTONE_USER, KEYSTONE_GROUP)
    subprocess.call(['keystone-manage', cmd,
                     '--keystone-user=%s' % KEYSTONE_USER,
                     '--keystone-group=%s' % KEYSTONE_GROUP])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['fernet_setup', 'fernet_rotate'])
    args = parser.parse_args()

    read_kube_config()
    secret = get_secret_definition(SECRET_NAME)
    if not secret:
        LOG.error("Secret '%s' does not exist.", SECRET_NAME)
        sys.exit(1)

    if args.command == 'fernet_rotate':
        LOG.info("Copying existing fernet keys from secret '%s' to %s.",
                 SECRET_NAME, FERNET_DIR)
        write_to_files(secret['data'])

    execute_command(args.command)

    LOG.info("Updating data for '%s' secret.", SECRET_NAME)
    updated_keys = get_keys_data()
    secret['data'] = updated_keys
    if not update_secret(SECRET_NAME, secret):
        sys.exit(1)
    LOG.info("%s fernet keys have been placed to secret '%s'",
             len(updated_keys), SECRET_NAME)
    LOG.debug("Placed keys: %s", updated_keys)
    LOG.info("Fernet keys %s has been completed",
             "rotation" if args.command == 'fernet_rotate' else "generation")

if __name__ == "__main__":
    main()