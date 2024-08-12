/*
 * Copyright (C) 2024 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React, {useCallback} from 'react'
import {useNode, type Node} from '@craftjs/core'
import {IconButton} from '@instructure/ui-buttons'
import {Flex} from '@instructure/ui-flex'
import {Menu} from '@instructure/ui-menu'
import {Text} from '@instructure/ui-text'
import {
  IconArrowOpenDownLine,
  IconArrowOpenEndLine,
  IconTextStartLine,
  IconTextCenteredLine,
  IconTextEndLine,
} from '@instructure/ui-icons'
import {useScope} from '@canvas/i18n'
import {type GroupLayout, type GroupAlignment, type GroupBlockProps} from './types'

const I18n = useScope('block-editor')

export const GroupBlockToolbar = () => {
  const {
    actions: {setProp},
    props,
  } = useNode((node: Node) => ({
    props: node.data.props,
  }))

  const handleChangeDirection = useCallback(
    (e, value) => {
      setProp((prps: GroupBlockProps) => {
        prps.layout = value as GroupLayout
      })
    },
    [setProp]
  )

  const handleChangeAlignment = useCallback(
    (e, value) => {
      setProp((prps: GroupBlockProps) => {
        prps.alignment = value as GroupAlignment
      })
    },
    [setProp]
  )

  const renderAlignmentIcon = () => {
    switch (props.alignment) {
      case 'start':
        return <IconTextStartLine size="x-small" />
      case 'center':
        return <IconTextCenteredLine size="x-small" />
      case 'end':
        return <IconTextEndLine size="x-small" />
    }
  }

  return (
    <Flex>
      <Menu
        trigger={
          <IconButton
            size="small"
            withBorder={false}
            withBackground={false}
            screenReaderLabel={I18n.t('Layout direction')}
          >
            {props.layout === 'column' ? <IconArrowOpenDownLine /> : <IconArrowOpenEndLine />}
          </IconButton>
        }
        onSelect={handleChangeDirection}
      >
        <Menu.Item type="checkbox" value="column" defaultSelected={props.layout === 'column'}>
          {I18n.t('Column')}
        </Menu.Item>
        <Menu.Item type="checkbox" value="row" defaultSelected={props.layout === 'row'}>
          {I18n.t('Row')}
        </Menu.Item>
      </Menu>
      <Menu
        trigger={
          <IconButton
            size="small"
            withBorder={false}
            withBackground={false}
            screenReaderLabel={I18n.t('Align')}
          >
            {renderAlignmentIcon()}
          </IconButton>
        }
        onSelect={handleChangeAlignment}
      >
        <Menu.Item type="checkbox" value="start" defaultSelected={props.alignment === 'start'}>
          <Flex gap="x-small">
            <IconTextStartLine size="x-small" />
            <Text>{I18n.t('Align to start')}</Text>
          </Flex>
        </Menu.Item>
        <Menu.Item type="checkbox" value="center" defaultSelected={props.layout === 'center'}>
          <Flex gap="x-small">
            <IconTextCenteredLine size="x-small" />
            <Text>{I18n.t('Align to center')}</Text>
          </Flex>
        </Menu.Item>
        <Menu.Item type="checkbox" value="end" defaultSelected={props.layout === 'end'}>
          <Flex gap="x-small">
            <IconTextEndLine size="x-small" />
            <Text>{I18n.t('Align to end')}</Text>
          </Flex>
        </Menu.Item>
      </Menu>
    </Flex>
  )
}
