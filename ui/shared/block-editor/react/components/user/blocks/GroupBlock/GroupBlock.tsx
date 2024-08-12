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

import React, {useEffect} from 'react'
import {Element, useEditor, useNode, type Node} from '@craftjs/core'

import {NoSections} from '../../common'
import {Container} from '../Container/Container'
import {useClassNames, notDeletableIfLastChild} from '../../../../utils'
import {type GroupBlockProps} from './types'
import {GroupBlockToolbar} from './GroupBlockToolbar'
import {BlockResizer} from '../../../editor/BlockResizer'

import {useScope as useI18nScope} from '@canvas/i18n'

const I18n = useI18nScope('block-editor')

export const GroupBlock = (props: GroupBlockProps) => {
  const {
    alignment = GroupBlock.craft.defaultProps.alignment,
    layout = GroupBlock.craft.defaultProps.layout,
    resizable = GroupBlock.craft.defaultProps.resizable,
  } = props
  const {actions, enabled} = useEditor(state => ({
    enabled: state.options.enabled,
  }))
  const clazz = useClassNames(enabled, {empty: false}, [
    'block',
    'group-block',
    `${layout}-layout`,
    `${alignment}-align`,
  ])
  const {node} = useNode((n: Node) => {
    return {
      node: n,
    }
  })

  useEffect(() => {
    if (resizable !== node.data.custom.isResizable) {
      actions.setCustom(node.id, (custom: Object) => {
        // @ts-expect-error
        custom.isResizable = resizable
      })
    }
  }, [actions, node.data.custom.isResizable, node.id, resizable])

  return (
    <Container className={clazz} id={`group-${node.id}`}>
      <Element
        id="group-block__inner"
        is={NoSections}
        canvas={true}
        className="group-block__inner"
      />
    </Container>
  )
}

GroupBlock.craft = {
  displayName: I18n.t('Group'),
  defaultProps: {
    alignment: 'start',
    layout: 'column',
    resizable: true,
  },
  rules: {
    canMoveIn: (incomingNodes: Node[]) => {
      return !incomingNodes.some(
        (incomingNode: Node) =>
          incomingNode.data.custom.isSection || incomingNode.data.name === 'GroupBlock'
      )
    },
  },
  related: {
    toolbar: GroupBlockToolbar,
    resizer: BlockResizer,
  },
  custom: {
    isDeletable: (nodeId: string, query: any) => {
      const parentId = query.node(nodeId).get().data.parent
      const parent = query.node(parentId).get()
      return parent?.data.name !== 'ColumnsSectionInner' || notDeletableIfLastChild(nodeId, query)
    },
    isResizable: true,
  },
}
